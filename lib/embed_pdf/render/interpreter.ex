defmodule EmbedPdf.Render.GState do
  @moduledoc "Graphics and text state (ISO 32000-1, 8.4 and 9.3)."
  alias EmbedPdf.Render.Matrix

  defstruct ctm: Matrix.identity(),
            # the CTM at the start of the current content stream (page, form
            # or glyph): patterns are defined relative to it
            base_ctm: Matrix.identity(),
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

  ## Limits

  A page gets a work budget (`new_budget/0`): one unit per operator and per
  glyph shown, more for what costs more (nested content streams by their
  size, images and patterns by theirs, colors by their tint function).
  Form XObjects, Type 3 glyph procedures and the interpreters an emitter
  starts while handling an event (soft masks, patterns) all draw on the
  same budget and nesting depth; pass `budget:` to share it between runs
  that follow one another (a page and its annotation appearances). When
  the budget runs out interpretation stops quietly and what was drawn so
  far is returned.

      config :embedpdf_ex, max_page_operators: 3_000_000
  """

  alias EmbedPdf.Font
  alias EmbedPdf.PDF.{Content, Document, Page, Stream}
  alias EmbedPdf.Render.{ColorSpace, GState, Matrix}

  # content streams nested this deep (forms, glyph procedures, patterns,
  # soft masks, counted together) are not drawn
  @max_depth 12
  # clipping paths in force at once; further ones are ignored
  @max_clips 256
  @max_dash 32
  # forms and Type 3 glyph procedures kept parsed: the size of one, and of
  # all of them, in bytes of content
  @max_kept_stream 16_384
  @max_kept_bytes 1_000_000
  @default_operators 3_000_000
  @default_image_bytes 512_000_000
  @budget_key {__MODULE__, :budget}

  @type emit :: (tuple(), term() -> term())
  @opaque budget :: :counters.counters_ref()

  # ---------------------------------------------------------------- budget

  @doc """
  A fresh work budget: `:max_page_operators` units of work (default
  #{@default_operators}) and `:max_page_image_bytes` of decoded image
  samples (default #{@default_image_bytes}).
  """
  @spec new_budget() :: budget()
  def new_budget do
    # 1: work left, 2: depth for the next interpreter started, 3: image bytes left
    budget = :counters.new(3, [])
    :counters.put(budget, 1, limit(:max_page_operators, @default_operators))
    :counters.put(budget, 3, limit(:max_page_image_bytes, @default_image_bytes))
    budget
  end

  defp limit(key, default) do
    case Application.get_env(:embedpdf_ex, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  @doc """
  Charges `units` of work to the budget of the interpreter running in this
  process, for work done on its behalf while handling an event. Returns
  `false` once the budget is spent (always `true` outside a run).
  """
  @spec charge(non_neg_integer()) :: boolean()
  def charge(units) do
    case Process.get(@budget_key) do
      nil -> true
      budget -> spend(budget, 1, units)
    end
  end

  @doc """
  Charges decoded image bytes to the running interpreter's budget; `false`
  when the page has used up its share.
  """
  @spec charge_image(non_neg_integer()) :: boolean()
  def charge_image(bytes) do
    case Process.get(@budget_key) do
      nil -> true
      budget -> spend(budget, 3, bytes)
    end
  end

  defp spend(budget, slot, units) do
    if :counters.get(budget, slot) > 0 do
      :counters.sub(budget, slot, max(units, 0))
      true
    else
      false
    end
  end

  # one unit per operator; false when nothing is left
  defp spend(%{budget: budget}, units), do: spend(budget, 1, units)

  # Makes the state's budget the process's current one while `fun` runs, so
  # that interpreters started from event handlers continue from it.
  defp scoped(state, fun) do
    budget = state.budget
    previous = Process.put(@budget_key, budget)
    outer_depth = :counters.get(budget, 2)
    :counters.put(budget, 2, state.depth + 1)

    try do
      fun.(state)
    after
      :counters.put(budget, 2, outer_depth)
      if previous, do: Process.put(@budget_key, previous), else: Process.delete(@budget_key)
    end
  end

  defp publish_depth(state, depth), do: :counters.put(state.budget, 2, depth + 1)

  @doc """
  Runs a page's content. Options:

    * `:ctm` – base transform (default identity: PDF user space)
    * `:text_only` – skip images, shadings and Type 3 glyph procedures
    * `:gs` – a `GState` to start from (its `ctm` and `clip` are replaced)
    * `:budget` – a budget from `new_budget/0` to draw on (default: the one
      of the interpreter this run is nested in, or a fresh one)
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
    # 0 for a page; inside another interpreter (a pattern cell) one level down
    depth = :counters.get(state.budget, 2)
    state = %{state | depth: depth, parsed: if(depth == 0, do: MapSet.new())}

    if state.depth > @max_depth or not nested_stream(state, content) do
      acc
    else
      scoped(state, fn state -> exec(parse_within(state, content), state) end).acc
    end
  end

  # a content stream run from inside another one is paid for by its size
  defp nested_stream(%{depth: 0}, _content), do: true
  defp nested_stream(state, content), do: spend(state, stream_cost(content))

  # reading a stream costs by the byte, whatever it then has to run
  defp stream_cost(content), do: 1 + div(byte_size(content), 4)

  @doc """
  Runs a form XObject (such as an annotation appearance) drawn with
  `matrix` (form space → user space) on top of `ctm`.
  """
  @spec run_form(Document.t(), Stream.t(), Matrix.t(), emit(), term(), keyword()) :: term()
  def run_form(doc, %Stream{} = form, ctm, emit, acc, opts \\ []) do
    state = new_state(doc, %{}, ctm, emit, acc, opts)
    # the form itself is the nested level
    state = %{state | depth: max(:counters.get(state.budget, 2) - 1, 0)}
    scoped(state, fn state -> draw_form(state, form, nil) end).acc
  end

  defp new_state(doc, resources, ctm, emit, acc, opts) do
    initial =
      case Keyword.get(opts, :gs) do
        %GState{} = gs -> %{gs | ctm: ctm, base_ctm: ctm, clip: []}
        _ -> %GState{ctm: ctm, base_ctm: ctm}
      end

    %{
      doc: doc,
      resources: resources || %{},
      gs: initial,
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
      # parsed color spaces by {resources id, name}
      spaces: %{},
      res_id: :root,
      depth: 0,
      forms: MapSet.new(),
      # the forms a page has read (nil: this is not a page's own content)
      parsed: nil,
      # forms and Type 3 glyph procedures kept parsed, and their size so far
      streams: {%{}, 0},
      oc: oc_config(doc),
      mc: [],
      budget: Keyword.get(opts, :budget) || Process.get(@budget_key) || new_budget(),
      opts: opts
    }
  end

  defp exec(ops, state) do
    Enum.reduce_while(ops, state, fn {op, args}, st ->
      if spend(st, 1) do
        {:cont,
         try do
           op(op, args, st)
         rescue
           _ ->
             publish_depth(st, st.depth)
             st
         end}
      else
        {:halt, st}
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
    do: put_gs(s, :dash, {arr |> Enum.filter(&is_number/1) |> Enum.take(@max_dash), phase})

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

  defp op("CS", [name], s) do
    {cs, s} = color_space(s, name)
    set_space(s, :stroke, cs)
  end

  defp op("cs", [name], s) do
    {cs, s} = color_space(s, name)
    set_space(s, :fill, cs)
  end

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
              else: emit_image(s, xobj, byte_size(xobj.raw))

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
    if s.opts[:text_only], do: s, else: emit_image(s, image, inline_size(image))
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

  # each entry says whether content is visible at that level, the enclosing
  # ones included
  defp op("BMC", _, s), do: %{s | mc: [visible?(s) | s.mc]}

  defp op("BDC", [tag, props], s) do
    visible =
      if tag == "OC" do
        props = if is_binary(props), do: resource(s, "Properties", props), else: props
        oc_visible?(s, props)
      else
        true
      end

    %{s | mc: [visible and visible?(s) | s.mc]}
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

  # the emitter identifies images and patterns by their bytes: drawing one
  # costs in proportion
  defp emit_image(s, image, size) do
    if spend(s, div(size, 1024)),
      do: emit(s, {:image, %{image: image, gs: s.gs, resources: s.resources}}),
      else: s
  end

  defp inline_size(%{data: data}) when is_binary(data), do: byte_size(data)
  defp inline_size(_), do: 0

  defp pattern_cost(_s, nil), do: 0
  defp pattern_cost(_s, {%Stream{raw: raw}, _tint}), do: div(byte_size(raw), 1024)

  defp pattern_cost(s, {%{"Shading" => shading}, _tint}) do
    case Document.resolve(s.doc, shading) do
      %Stream{raw: raw} -> div(byte_size(raw), 1024)
      _ -> 0
    end
  end

  defp pattern_cost(_s, _), do: 0

  defp push_clip(clip, entry) do
    if length(clip) < @max_clips, do: clip ++ [entry], else: clip
  end

  defp color_space(%{res_id: nil} = s, name),
    do: {ColorSpace.parse(s.doc, name, s.resources), s}

  defp color_space(s, name) do
    key = {s.res_id, name}

    case s.spaces do
      %{^key => cs} ->
        {cs, s}

      _ ->
        cs = ColorSpace.parse(s.doc, name, s.resources)
        {cs, %{s | spaces: Map.put(s.spaces, key, cs)}}
    end
  end

  # Names the resource dictionary a content stream brings along, for the
  # color space cache (nil: not known to be the same one next time).
  defp resources_id({:ref, n, _}, _owner), do: {:res, n}
  defp resources_id(_direct, nil), do: nil
  defp resources_id(_direct, owner), do: owner

  defp close_path(s), do: %{s | path: [:h | s.path], cp: s.start}

  defp paint(s, fill, stroke?) do
    path = Enum.reverse(s.path)

    s =
      if path != [] and (fill != nil or stroke?) do
        patterns =
          if(fill, do: pattern_cost(s, s.gs.fill_pattern), else: 0) +
            if stroke?, do: pattern_cost(s, s.gs.stroke_pattern), else: 0

        if patterns == 0 or spend(s, patterns),
          do: emit(s, {:path, %{path: path, fill: fill, stroke: stroke?, gs: s.gs}}),
          else: s
      else
        s
      end

    s =
      case s.clip_rule do
        nil -> s
        rule -> put_gs(s, :clip, push_clip(s.gs.clip, {path, rule, s.gs.ctm}))
      end

    %{s | path: [], clip_rule: nil}
  end

  defp set_space(s, which, cs) do
    spend(s, color_cost(cs))
    color = initial_color(cs)

    case which do
      :fill -> %{s | gs: %{s.gs | fill_cs: cs, fill: color, fill_pattern: nil}}
      :stroke -> %{s | gs: %{s.gs | stroke_cs: cs, stroke: color, stroke_pattern: nil}}
    end
  end

  # converting a color runs the space's tint function
  defp color_cost(cs) when is_atom(cs), do: 0
  defp color_cost(cs), do: div(ColorSpace.cost(cs), 16)

  defp initial_color({:pattern, _}), do: {0.0, 0.0, 0.0}
  defp initial_color(cs), do: ColorSpace.to_rgb(cs, ColorSpace.initial(cs))

  defp set_color(s, which, args) do
    cs = if which == :fill, do: s.gs.fill_cs, else: s.gs.stroke_cs
    spend(s, color_cost(cs))
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

  defp font_for(s, name), do: load_font(s, get_in_resources_ref(s, "Font", name))

  defp load_font(s, ref) do
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
          dashes = arr |> Enum.take(@max_dash) |> Enum.map(&Document.resolve(doc, &1))
          put_gs(st, :dash, {dashes, phase})

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

        {"Font", [{:ref, _, _} = ref, size]} ->
          {font, st} = load_font(st, ref)
          %{st | gs: %{st.gs | font: font, font_size: size / 1}}

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
    Enum.reduce(Font.decode(s.gs.font, str), s, fn glyph, st ->
      if spend(st, 1), do: show_glyph(st, s, glyph), else: st
    end)
  end

  # `s` is the state the string started with
  defp show_glyph(st, s, {code, _cid, _uni, w0, n} = glyph) do
    gs = s.gs
    font = gs.font
    fs = gs.font_size
    th = gs.h_scale

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
  end

  defp draw_type3(s, font, code, trm) do
    case Font.type3_proc(font, code) do
      {proc, res} when s.depth < @max_depth ->
        case stream_ops(s, font.id && {:glyph, font.id, code}, proc) do
          {nil, s} -> s
          {ops, s} -> run_type3(s, font, ops, res, trm)
        end

      _ ->
        s
    end
  end

  defp run_type3(s, font, ops, res, trm) do
    ctm = Matrix.multiply(font.font_matrix, trm)
    saved = {s.gs, s.stack, s.resources, s.res_id, s.path, s.tm, s.tlm, s.mc}

    inner = %{
      s
      | gs: %{s.gs | ctm: ctm, base_ctm: ctm},
        stack: [],
        resources: res || s.resources,
        res_id: if(res, do: font.id && {:t3, font.id}, else: s.res_id),
        path: [],
        depth: s.depth + 1
    }

    publish_depth(inner, inner.depth)
    inner = exec(ops, inner)
    publish_depth(s, s.depth)
    {gs, stack, resources, res_id, path, tm, tlm, mc} = saved

    %{
      inner
      | gs: gs,
        stack: stack,
        resources: resources,
        res_id: res_id,
        path: path,
        tm: tm,
        tlm: tlm,
        mc: mc,
        depth: s.depth
    }
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
    own_resources = Document.resolve(doc, dict["Resources"])
    resources = own_resources || s.resources

    res_id =
      if own_resources,
        do: resources_id(dict["Resources"], key && {:form, key}),
        else: s.res_id

    group? = match?(%{"S" => "Transparency"}, Document.resolve(doc, dict["Group"]))

    gs = %{s.gs | ctm: ctm, base_ctm: ctm}

    gs =
      case bbox do
        {x0, y0, x1, y1} ->
          %{gs | clip: push_clip(gs.clip, {[{:re, x0, y0, x1 - x0, y1 - y0}], :nonzero, ctm})}

        nil ->
          gs
      end

    saved = {s.gs, s.stack, s.resources, s.res_id, s.path, s.tm, s.tlm, s.forms, s.mc}

    inner = %{
      s
      | gs: gs,
        stack: [],
        resources: resources,
        res_id: res_id,
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

    publish_depth(inner, inner.depth)

    inner =
      case stream_ops(inner, key && {:form, key}, form) do
        {nil, inner} -> inner
        {ops, inner} -> exec(ops, inner)
      end

    publish_depth(s, s.depth)
    inner = if group?, do: emit(%{inner | mc: s.mc}, {:group_end, %{gs: gs}}), else: inner

    {g, stack, res, res_id, path, tm, tlm, forms, mc} = saved

    %{
      inner
      | gs: g,
        stack: stack,
        resources: res,
        res_id: res_id,
        path: path,
        tm: tm,
        tlm: tlm,
        forms: forms,
        depth: s.depth,
        mc: mc
    }
  end

  # Parses no more operations than the budget still lets run: the parsed
  # list is several times the size of its stream.
  defp parse_within(%{budget: budget}, content),
    do: Content.parse(content, max_ops: max(:counters.get(budget, 1), 0) + 1)

  # The operations of a form or a glyph procedure, or nil when the budget
  # does not let it be read. `key` names the stream (nil: not known to be
  # the same one next time); small ones are kept parsed, so that a symbol
  # or a glyph drawn a thousand times is read once.
  defp stream_ops(s, key, stream) do
    case s.streams do
      {%{^key => ops}, _size} when key != nil ->
        {ops, s}

      {kept, size} ->
        content = Document.stream_data(s.doc, stream) || ""
        {cost, s} = read_cost(s, key, content)

        if spend(s, cost) do
          ops = parse_within(s, content)
          size = size + byte_size(content)

          if key != nil and byte_size(content) <= @max_kept_stream and size <= @max_kept_bytes,
            do: {ops, %{s | streams: {Map.put(kept, key, ops), size}}},
            else: {ops, s}
        else
          {nil, s}
        end
    end
  end

  # A page reads each of its forms once for nothing, as it does its own
  # content; reading one again, or reading anything on behalf of what may be
  # drawn many times over (a glyph, a pattern, a soft mask, an appearance),
  # is paid for by its size.
  defp read_cost(%{parsed: %MapSet{} = parsed} = s, {:form, _} = key, content) do
    if MapSet.member?(parsed, key),
      do: {stream_cost(content), s},
      else: {1, %{s | parsed: MapSet.put(parsed, key)}}
  end

  defp read_cost(s, _key, content), do: {stream_cost(content), s}

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

  defp visible?(%{mc: [false | _]}), do: false
  defp visible?(_), do: true

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
          spend(s, div(length(ocgs), 16))
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
