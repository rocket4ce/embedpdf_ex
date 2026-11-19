defmodule EmbedPdf.Render.GState do
  @moduledoc "Graphics and text state (ISO 32000-1, 8.4 and 9.3)."
  alias EmbedPdf.Render.Matrix

  defstruct ctm: Matrix.identity(),
            clip: [],
            fill_cs: :gray,
            fill: {0.0, 0.0, 0.0},
            fill_pattern: nil,
            stroke_cs: :gray,
            stroke: {0.0, 0.0, 0.0},
            stroke_pattern: nil,
            fill_alpha: 1.0,
            stroke_alpha: 1.0,
            line_width: 1.0,
            line_cap: 0,
            line_join: 0,
            miter_limit: 10.0,
            dash: {[], 0},
            blend: "Normal",
            soft_mask: nil,
            font: nil,
            font_size: 0.0,
            char_spacing: 0.0,
            word_spacing: 0.0,
            h_scale: 1.0,
            leading: 0.0,
            render_mode: 0,
            rise: 0.0

  @type t :: %__MODULE__{}
end

defmodule EmbedPdf.Render.Interpreter do
  @moduledoc """
  Executes content streams and reports what they draw as events, in PDF
  user space with the graphics state at that moment:

    * `{:path, %{path: cmds, fill: nil | :nonzero | :evenodd, stroke: bool, gs: gs}}`
      where cmds are `{:m, x, y}`, `{:l, x, y}`, `{:c, x1, y1, x2, y2, x, y}`,
      `{:re, x, y, w, h}` and `:h`, to be drawn under `gs.ctm`
    * `{:glyph, %{font: font, glyph: glyph, trm: matrix, gs: gs}}` for every
      glyph shown (`trm` maps glyph space for size 1 to device space;
      `gs.render_mode` says whether to fill, stroke or hide it)
    * `{:image, %{image: stream | %{dict:, data:}, gs: gs, resources: res}}`
      (the image fills the unit square under `gs.ctm`)
    * `{:shading, %{shading: shading, gs: gs, resources: res}}`
    * `{:group_begin, %{gs: gs, bbox: rect, form: stream}}` and
      `{:group_end, %{gs: gs}}` around transparency groups

  `gs.clip` holds the clipping paths in force as `{cmds, rule, ctm}`.

  The emitter is `fun(event, acc) -> acc`; the interpreter threads `acc`
  through and returns it.
  """

  alias EmbedPdf.Font
  alias EmbedPdf.PDF.{Content, Document, Page, Stream}
  alias EmbedPdf.Render.{ColorSpace, GState, Matrix}

  @max_depth 24

  @type emit :: (tuple(), term() -> term())

  @doc """
  Runs a page's content. Options:

    * `:ctm` – base transform (default identity: PDF user space)
    * `:text_only` – skip images, shadings and Type 3 glyph procedures
  """
  @spec run_page(Document.t(), Page.t(), emit(), term(), keyword()) :: term()
  def run_page(doc, %Page{} = page, emit, acc, opts \\ []) do
    content = Document.page_content(doc, page)
    run(doc, content, page.resources, Keyword.get(opts, :ctm, Matrix.identity()), emit, acc, opts)
  end

  @doc "Runs a content stream binary with the given resources and base CTM."
  @spec run(Document.t(), binary(), map(), Matrix.t(), emit(), term(), keyword()) :: term()
  def run(doc, content, resources, ctm, emit, acc, opts \\ []) do
    state = new_state(doc, resources, ctm, emit, acc, opts)
    state = exec(Content.parse(content), state)
    state.acc
  end

  @doc """
  Runs a form XObject (such as an annotation appearance) drawn with
  `matrix` (form space → user space) on top of `ctm`.
  """
  @spec run_form(Document.t(), Stream.t(), Matrix.t(), emit(), term(), keyword()) :: term()
  def run_form(doc, %Stream{} = form, ctm, emit, acc, opts \\ []) do
    state = new_state(doc, %{}, ctm, emit, acc, opts)
    state = draw_form(state, form, nil)
    state.acc
  end

  defp new_state(doc, resources, ctm, emit, acc, opts) do
    %{
      doc: doc,
      resources: resources || %{},
      gs: %GState{ctm: ctm},
      stack: [],
      path: [],
      cp: {0.0, 0.0},
      start: {0.0, 0.0},
      clip_rule: nil,
      tm: Matrix.identity(),
      tlm: Matrix.identity(),
      emit: emit,
      acc: acc,
      fonts: Keyword.get(opts, :fonts, %{}),
      depth: 0,
      forms: MapSet.new(),
      oc: oc_config(doc),
      mc: [],
      opts: opts
    }
  end

  defp exec(ops, state) do
    Enum.reduce(ops, state, fn {op, args}, st ->
      try do
        op(op, args, st)
      rescue
        _ -> st
      end
    end)
  end

  defp emit(state, event) do
    if visible?(state), do: %{state | acc: state.emit.(event, state.acc)}, else: state
  end

  # ---------------------------------------------------------------- general state

  defp op("q", _, s), do: %{s | stack: [s.gs | s.stack]}
  defp op("Q", _, %{stack: [gs | rest]} = s), do: %{s | gs: gs, stack: rest}
  defp op("Q", _, s), do: s

  defp op("cm", [a, b, c, d, e, f], s) do
    m = Enum.map([a, b, c, d, e, f], &(&1 / 1))
    put_gs(s, :ctm, Matrix.multiply(m, s.gs.ctm))
  end

  defp op("w", [w], s), do: put_gs(s, :line_width, w / 1)
  defp op("J", [c], s), do: put_gs(s, :line_cap, trunc(c))
  defp op("j", [j], s), do: put_gs(s, :line_join, trunc(j))
  defp op("M", [m], s), do: put_gs(s, :miter_limit, m / 1)

  defp op("d", [arr, phase], s) when is_list(arr),
    do: put_gs(s, :dash, {Enum.filter(arr, &is_number/1), phase})

  defp op("ri", _, s), do: s
  defp op("i", _, s), do: s
  defp op("gs", [name], s), do: apply_ext_gstate(s, resource(s, "ExtGState", name))

  # ---------------------------------------------------------------- paths

  defp op("m", [x, y], s),
    do: %{s | path: [{:m, x / 1, y / 1} | s.path], cp: {x / 1, y / 1}, start: {x / 1, y / 1}}

  defp op("l", [x, y], s), do: %{s | path: [{:l, x / 1, y / 1} | s.path], cp: {x / 1, y / 1}}

  defp op("c", [x1, y1, x2, y2, x3, y3], s),
    do: %{
      s
      | path: [{:c, x1 / 1, y1 / 1, x2 / 1, y2 / 1, x3 / 1, y3 / 1} | s.path],
        cp: {x3 / 1, y3 / 1}
    }

  defp op("v", [x2, y2, x3, y3], s) do
    {cx, cy} = s.cp
    %{s | path: [{:c, cx, cy, x2 / 1, y2 / 1, x3 / 1, y3 / 1} | s.path], cp: {x3 / 1, y3 / 1}}
  end

  defp op("y", [x1, y1, x3, y3], s),
    do: %{
      s
      | path: [{:c, x1 / 1, y1 / 1, x3 / 1, y3 / 1, x3 / 1, y3 / 1} | s.path],
        cp: {x3 / 1, y3 / 1}
    }

  defp op("h", _, s), do: %{s | path: [:h | s.path], cp: s.start}

  defp op("re", [x, y, w, h], s),
    do: %{
      s
      | path: [{:re, x / 1, y / 1, w / 1, h / 1} | s.path],
        cp: {x / 1, y / 1},
        start: {x / 1, y / 1}
    }

  defp op("S", _, s), do: paint(s, nil, true)
  defp op("s", _, s), do: s |> close_path() |> paint(nil, true)
  defp op(f, _, s) when f in ["f", "F"], do: paint(s, :nonzero, false)
  defp op("f*", _, s), do: paint(s, :evenodd, false)
  defp op("B", _, s), do: paint(s, :nonzero, true)
  defp op("B*", _, s), do: paint(s, :evenodd, true)
  defp op("b", _, s), do: s |> close_path() |> paint(:nonzero, true)
  defp op("b*", _, s), do: s |> close_path() |> paint(:evenodd, true)
  defp op("n", _, s), do: paint(s, nil, false)
  defp op("W", _, s), do: %{s | clip_rule: :nonzero}
  defp op("W*", _, s), do: %{s | clip_rule: :evenodd}

  # ---------------------------------------------------------------- color

  defp op("CS", [name], s), do: set_space(s, :stroke, ColorSpace.parse(s.doc, name, s.resources))
  defp op("cs", [name], s), do: set_space(s, :fill, ColorSpace.parse(s.doc, name, s.resources))
  defp op(o, args, s) when o in ["SC", "SCN"], do: set_color(s, :stroke, args)
  defp op(o, args, s) when o in ["sc", "scn"], do: set_color(s, :fill, args)
  defp op("G", [g], s), do: s |> set_space(:stroke, :gray) |> set_color(:stroke, [g])
  defp op("g", [g], s), do: s |> set_space(:fill, :gray) |> set_color(:fill, [g])
  defp op("RG", [r, g, b], s), do: s |> set_space(:stroke, :rgb) |> set_color(:stroke, [r, g, b])
  defp op("rg", [r, g, b], s), do: s |> set_space(:fill, :rgb) |> set_color(:fill, [r, g, b])

  defp op("K", [c, m, y, k], s),
    do: s |> set_space(:stroke, :cmyk) |> set_color(:stroke, [c, m, y, k])

  defp op("k", [c, m, y, k], s),
    do: s |> set_space(:fill, :cmyk) |> set_color(:fill, [c, m, y, k])

  # ---------------------------------------------------------------- text

  defp op("BT", _, s), do: %{s | tm: Matrix.identity(), tlm: Matrix.identity()}
  defp op("ET", _, s), do: s
  defp op("Tc", [v], s), do: put_gs(s, :char_spacing, v / 1)
  defp op("Tw", [v], s), do: put_gs(s, :word_spacing, v / 1)
  defp op("Tz", [v], s), do: put_gs(s, :h_scale, v / 100)
  defp op("TL", [v], s), do: put_gs(s, :leading, v / 1)
  defp op("Tr", [v], s), do: put_gs(s, :render_mode, trunc(v))
  defp op("Ts", [v], s), do: put_gs(s, :rise, v / 1)

  defp op("Tf", [name, size], s) do
    {font, s} = font_for(s, name)
    %{s | gs: %{s.gs | font: font, font_size: size / 1}}
  end

  defp op("Td", [tx, ty], s) do
    tlm = Matrix.multiply(Matrix.translate(tx, ty), s.tlm)
    %{s | tlm: tlm, tm: tlm}
  end

  defp op("TD", [tx, ty], s), do: s |> put_gs(:leading, -ty / 1) |> then(&op("Td", [tx, ty], &1))

  defp op("Tm", [a, b, c, d, e, f], s) do
    m = Enum.map([a, b, c, d, e, f], &(&1 / 1))
    %{s | tm: m, tlm: m}
  end

  defp op("T*", _, s), do: op("Td", [0, -s.gs.leading], s)
  defp op("Tj", [{:string, str}], s), do: show(s, str)
  defp op("'", [{:string, str}], s), do: s |> then(&op("T*", [], &1)) |> show(str)

  defp op("\"", [aw, ac, {:string, str}], s) do
    s
    |> put_gs(:word_spacing, aw / 1)
    |> put_gs(:char_spacing, ac / 1)
    |> then(&op("T*", [], &1))
    |> show(str)
  end

  defp op("TJ", [items], s) when is_list(items) do
    Enum.reduce(items, s, fn
      {:string, str}, st ->
        show(st, str)

      n, st when is_number(n) ->
        gs = st.gs

        if st.gs.font && st.gs.font.vertical? do
          %{st | tm: Matrix.multiply(Matrix.translate(0, -n / 1000 * gs.font_size), st.tm)}
        else
          tx = -n / 1000 * gs.font_size * gs.h_scale
          %{st | tm: Matrix.multiply(Matrix.translate(tx, 0), st.tm)}
        end

      _, st ->
        st
    end)
  end

  # ---------------------------------------------------------------- XObjects, images, shadings

  defp op("Do", [name], s) do
    case resource(s, "XObject", name) do
      %Stream{dict: dict} = xobj ->
        case Document.resolve(s.doc, dict["Subtype"]) do
          "Image" ->
            if s.opts[:text_only] == true or not oc_visible?(s, dict["OC"]),
              do: s,
              else: emit(s, {:image, %{image: xobj, gs: s.gs, resources: s.resources}})

          "Form" ->
            ref = get_in_resources_ref(s, "XObject", name)
            draw_form(s, xobj, ref)

          _ ->
            s
        end

      _ ->
        s
    end
  end

  defp op("BI", [image], s) do
    if s.opts[:text_only],
      do: s,
      else: emit(s, {:image, %{image: image, gs: s.gs, resources: s.resources}})
  end

  defp op("sh", [name], s) do
    if s.opts[:text_only] do
      s
    else
      case resource(s, "Shading", name) do
        nil -> s
        sh -> emit(s, {:shading, %{shading: sh, gs: s.gs, resources: s.resources}})
      end
    end
  end

  # ---------------------------------------------------------------- marked content

  defp op("BMC", _, s), do: %{s | mc: [true | s.mc]}

  defp op("BDC", [tag, props], s) do
    visible =
      if tag == "OC" do
        props = if is_binary(props), do: resource(s, "Properties", props), else: props
        oc_visible?(s, props)
      else
        true
      end

    %{s | mc: [visible | s.mc]}
  end

  defp op("EMC", _, %{mc: [_ | rest]} = s), do: %{s | mc: rest}
  defp op("EMC", _, s), do: s

  # Type 3 glyph metrics and compatibility sections
  defp op("d0", _, s), do: s
  defp op("d1", _, s), do: s
  defp op("BX", _, s), do: s
  defp op("EX", _, s), do: s
  defp op("MP", _, s), do: s
  defp op("DP", _, s), do: s
  defp op(_unknown, _, s), do: s

  # ---------------------------------------------------------------- helpers

  defp put_gs(s, key, value), do: %{s | gs: Map.put(s.gs, key, value)}

  defp close_path(s), do: %{s | path: [:h | s.path], cp: s.start}

  defp paint(s, fill, stroke?) do
    path = Enum.reverse(s.path)

    s =
      if path != [] and (fill != nil or stroke?),
        do: emit(s, {:path, %{path: path, fill: fill, stroke: stroke?, gs: s.gs}}),
        else: s

    s =
      case s.clip_rule do
        nil -> s
        rule -> put_gs(s, :clip, s.gs.clip ++ [{path, rule, s.gs.ctm}])
      end

    %{s | path: [], clip_rule: nil}
  end

  defp set_space(s, which, cs) do
    color = initial_color(cs)

    case which do
      :fill -> %{s | gs: %{s.gs | fill_cs: cs, fill: color, fill_pattern: nil}}
      :stroke -> %{s | gs: %{s.gs | stroke_cs: cs, stroke: color, stroke_pattern: nil}}
    end
  end

  defp initial_color({:pattern, _}), do: {0.0, 0.0, 0.0}
  defp initial_color(cs), do: ColorSpace.to_rgb(cs, ColorSpace.initial(cs))

  defp set_color(s, which, args) do
    cs = if which == :fill, do: s.gs.fill_cs, else: s.gs.stroke_cs
    nums = Enum.filter(args, &is_number/1)

    {color, pattern} =
      case {cs, List.last(args)} do
        {{:pattern, under}, name} when is_binary(name) ->
          pattern = resource(s, "Pattern", name)
          tint = if under && nums != [], do: ColorSpace.to_rgb(under, nums), else: nil
          {tint || {0.0, 0.0, 0.0}, {pattern, tint}}

        {{:pattern, _}, _} ->
          {{0.0, 0.0, 0.0}, nil}

        _ ->
          {ColorSpace.to_rgb(cs, nums), nil}
      end

    case which do
      :fill -> %{s | gs: %{s.gs | fill: color, fill_pattern: pattern}}
      :stroke -> %{s | gs: %{s.gs | stroke: color, stroke_pattern: pattern}}
    end
  end

  defp resource(s, category, name) do
    Document.get(s.doc, Document.get(s.doc, s.resources, category), name)
  end

  defp get_in_resources_ref(s, category, name) do
    case Document.get(s.doc, s.resources, category) do
      %{} = dict -> Map.get(dict, name)
      _ -> nil
    end
  end

  defp font_for(s, name) do
    ref = get_in_resources_ref(s, "Font", name)

    key =
      case ref do
        {:ref, n, _} -> n
        nil -> :default
        other -> :erlang.phash2(other)
      end

    case Map.fetch(s.fonts, key) do
      {:ok, font} ->
        {font, s}

      :error ->
        font =
          if ref == nil,
            do: Font.load(s.doc, %{"Subtype" => "Type1", "BaseFont" => "Helvetica"}),
            else: Font.load(s.doc, ref)

        {font, %{s | fonts: Map.put(s.fonts, key, font)}}
    end
  end

  defp apply_ext_gstate(s, gs_dict) when is_map(gs_dict) do
    doc = s.doc

    Enum.reduce(gs_dict, s, fn {k, v}, st ->
      v = Document.resolve(doc, v)

      case {k, v} do
        {"LW", w} when is_number(w) ->
          put_gs(st, :line_width, w / 1)

        {"LC", c} when is_number(c) ->
          put_gs(st, :line_cap, trunc(c))

        {"LJ", j} when is_number(j) ->
          put_gs(st, :line_join, trunc(j))

        {"ML", m} when is_number(m) ->
          put_gs(st, :miter_limit, m / 1)

        {"D", [arr, phase]} when is_list(arr) ->
          put_gs(st, :dash, {Enum.map(arr, &Document.resolve(doc, &1)), phase})

        {"CA", a} when is_number(a) ->
          put_gs(st, :stroke_alpha, a / 1)

        {"ca", a} when is_number(a) ->
          put_gs(st, :fill_alpha, a / 1)

        {"BM", bm} when is_binary(bm) ->
          put_gs(st, :blend, bm)

        {"BM", [bm | _]} when is_binary(bm) ->
          put_gs(st, :blend, bm)

        {"SMask", "None"} ->
          put_gs(st, :soft_mask, nil)

        {"SMask", %{} = sm} ->
          put_gs(st, :soft_mask, Map.put(sm, "__ctm", st.gs.ctm))

        {"Font", [ref, size]} ->
          font = Font.load(doc, ref)
          %{st | gs: %{st.gs | font: font, font_size: size / 1}}

        _ ->
          st
      end
    end)
  end

  defp apply_ext_gstate(s, _), do: s

  # ---------------------------------------------------------------- text showing

  defp show(%{gs: %{font: nil}} = s, str) do
    {font, s} = font_for(s, nil)
    show(%{s | gs: %{s.gs | font: font}}, str)
  end

  defp show(s, str) do
    gs = s.gs
    font = gs.font
    fs = gs.font_size
    th = gs.h_scale

    Enum.reduce(Font.decode(font, str), s, fn {code, _cid, _uni, w0, n} = glyph, st ->
      trm =
        [fs * th, 0.0, 0.0, fs, 0.0, gs.rise]
        |> Matrix.multiply(st.tm)
        |> Matrix.multiply(gs.ctm)

      st = emit(st, {:glyph, %{font: font, glyph: glyph, trm: trm, gs: st.gs}})

      st =
        if font.type == "Type3" and s.opts[:text_only] != true,
          do: draw_type3(st, font, code, trm),
          else: st

      word = if code == 32 and n == 1, do: gs.word_spacing, else: 0.0

      if font.vertical? do
        ty = -(1.0 * fs) + gs.char_spacing + word
        %{st | tm: Matrix.multiply(Matrix.translate(0, ty), st.tm)}
      else
        tx = (w0 * fs + gs.char_spacing + word) * th
        %{st | tm: Matrix.multiply(Matrix.translate(tx, 0), st.tm)}
      end
    end)
  end

  defp draw_type3(s, font, code, trm) do
    case Font.type3_proc(font, code) do
      {proc, res} when s.depth < @max_depth ->
        data = Document.stream_data(s.doc, proc) || ""
        ctm = Matrix.multiply(font.font_matrix, trm)
        saved = {s.gs, s.stack, s.resources, s.path, s.tm, s.tlm, s.mc}

        inner = %{
          s
          | gs: %{s.gs | ctm: ctm},
            stack: [],
            resources: res || s.resources,
            path: [],
            depth: s.depth + 1
        }

        inner = exec(Content.parse(data), inner)
        {gs, stack, resources, path, tm, tlm, mc} = saved

        %{
          inner
          | gs: gs,
            stack: stack,
            resources: resources,
            path: path,
            tm: tm,
            tlm: tlm,
            mc: mc,
            depth: s.depth
        }

      _ ->
        s
    end
  end

  # ---------------------------------------------------------------- forms

  defp draw_form(s, %Stream{dict: dict} = form, ref) do
    doc = s.doc
    key = with {:ref, n, _} <- ref, do: n

    cond do
      s.depth >= @max_depth -> s
      key && MapSet.member?(s.forms, key) -> s
      not oc_visible?(s, dict["OC"]) -> s
      true -> do_draw_form(s, form, dict, doc, key)
    end
  end

  defp do_draw_form(s, form, dict, doc, key) do
    matrix = Matrix.from_pdf(Document.resolve(doc, dict["Matrix"]))
    ctm = Matrix.multiply(matrix, s.gs.ctm)
    bbox = Page.normalize_rect(Document.resolve(doc, dict["BBox"]), doc)
    resources = Document.resolve(doc, dict["Resources"]) || s.resources
    group? = match?(%{"S" => "Transparency"}, Document.resolve(doc, dict["Group"]))

    gs = %{s.gs | ctm: ctm}

    gs =
      case bbox do
        {x0, y0, x1, y1} ->
          %{gs | clip: gs.clip ++ [{[{:re, x0, y0, x1 - x0, y1 - y0}], :nonzero, ctm}]}

        nil ->
          gs
      end

    saved = {s.gs, s.stack, s.resources, s.path, s.tm, s.tlm, s.forms, s.mc}

    inner = %{
      s
      | gs: gs,
        stack: [],
        resources: resources,
        path: [],
        depth: s.depth + 1,
        forms: if(key, do: MapSet.put(s.forms, key), else: s.forms),
        mc: []
    }

    inner =
      if group?, do: emit(inner, {:group_begin, %{gs: gs, bbox: bbox, form: form}}), else: inner

    # inside a group the group's alpha is applied once, by the group
    inner =
      if group?,
        do: %{
          inner
          | gs: %{inner.gs | fill_alpha: 1.0, stroke_alpha: 1.0, soft_mask: nil, blend: "Normal"}
        },
        else: inner

    inner = exec(Content.parse(Document.stream_data(doc, form) || ""), inner)
    inner = if group?, do: emit(%{inner | mc: s.mc}, {:group_end, %{gs: gs}}), else: inner

    {g, stack, res, path, tm, tlm, forms, mc} = saved

    %{
      inner
      | gs: g,
        stack: stack,
        resources: res,
        path: path,
        tm: tm,
        tlm: tlm,
        forms: forms,
        depth: s.depth,
        mc: mc
    }
  end

  # ---------------------------------------------------------------- optional content

  defp oc_config(doc) do
    props = Document.get(doc, Document.catalog(doc), "OCProperties")

    case props do
      %{} ->
        d = Document.get(doc, props, "D") || %{}
        all = (Document.resolve(doc, props["OCGs"]) || []) |> Enum.map(&ref_key/1)
        on = (Document.resolve(doc, d["ON"]) || []) |> Enum.map(&ref_key/1)
        off = (Document.resolve(doc, d["OFF"]) || []) |> Enum.map(&ref_key/1)

        hidden =
          if Document.resolve(doc, d["BaseState"]) == "OFF",
            do: MapSet.new(all -- on),
            else: MapSet.new(off)

        hidden

      _ ->
        MapSet.new()
    end
  end

  defp ref_key({:ref, n, _}), do: n
  defp ref_key(_), do: nil

  defp visible?(%{mc: mc}), do: Enum.all?(mc)

  defp oc_visible?(_s, nil), do: true

  defp oc_visible?(s, value) do
    if MapSet.size(s.oc) == 0 do
      true
    else
      key = ref_key(value)
      dict = Document.resolve(s.doc, value)

      case dict do
        %{"Type" => "OCMD"} ->
          ocgs = s.doc |> Document.resolve(dict["OCGs"]) |> List.wrap() |> Enum.map(&ref_key/1)
          policy = Document.resolve(s.doc, dict["P"]) || "AnyOn"
          states = Enum.map(ocgs, &(not MapSet.member?(s.oc, &1)))

          case policy do
            "AllOn" -> Enum.all?(states)
            "AnyOff" -> Enum.any?(states, &(!&1))
            "AllOff" -> Enum.all?(states, &(!&1))
            _ -> states == [] or Enum.any?(states)
          end

        _ ->
          not MapSet.member?(s.oc, key)
      end
    end
  end
end
