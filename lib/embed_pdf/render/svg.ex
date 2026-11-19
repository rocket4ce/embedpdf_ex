defmodule EmbedPdf.Render.SVG do
  @moduledoc """
  Renders PDF pages to standalone SVG documents.

  The page is drawn in display orientation (its `/Rotate` plus an optional
  extra rotation) with one SVG unit per PDF point, so the image scales
  crisply at every zoom. Glyphs are drawn from their outlines when the font
  program is available, otherwise as SVG text in a similar system font.
  Clipping paths, soft masks, transparency groups, blend modes, gradients,
  tiling patterns and images (JPEG passed through, the rest as PNG) are
  supported; annotation appearances are drawn on top.

  Every `id` in the output starts with a per-page prefix (`p<index>`), so
  several pages can be inlined in one HTML document.
  """

  alias EmbedPdf.Font
  alias EmbedPdf.PDF.{Document, Page, Stream}

  alias EmbedPdf.Render.{
    AnnotationAppearance,
    ColorSpace,
    GState,
    Image,
    Interpreter,
    Matrix,
    Shading
  }

  @flip [1.0, 0.0, 0.0, -1.0, 0.0, 1.0]
  @text_scale 100
  @max_depth 4

  @blend_modes %{
    "Multiply" => "multiply",
    "Screen" => "screen",
    "Overlay" => "overlay",
    "Darken" => "darken",
    "Lighten" => "lighten",
    "ColorDodge" => "color-dodge",
    "ColorBurn" => "color-burn",
    "HardLight" => "hard-light",
    "SoftLight" => "soft-light",
    "Difference" => "difference",
    "Exclusion" => "exclusion",
    "Hue" => "hue",
    "Saturation" => "saturation",
    "Color" => "color",
    "Luminosity" => "luminosity"
  }

  defstruct [
    :doc,
    :page,
    :prefix,
    :w,
    :h,
    n: 0,
    body: [],
    defs: [],
    keys: %{},
    open: [],
    frames: [],
    clip_base: 0,
    run: nil,
    glyphs: %{},
    images: %{},
    depth: 0
  ]

  @doc """
  Renders page `index` to an SVG document.

  Options:

    * `:rotation` – extra clockwise rotation (0, 90, 180, 270)
    * `:annotations` – draw annotation appearances (default `true`)
    * `:skip_annotations` – object numbers of annotations not to draw
    * `:viewbox` – `{x0, y0, x1, y1}` region in display points (snapshots)
    * `:background` – page color (default `"#fff"`, `nil` for none)
    * `:id_prefix` – prefix for element ids (default `"p<index>"`)
  """
  @spec render_page(Document.t(), non_neg_integer(), keyword()) :: iodata()
  def render_page(doc, index, opts \\ []) do
    case Document.page(doc, index) do
      nil ->
        ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 612 792" width="612" height="792"/>)

      page ->
        rotation = normalize_rotation(Keyword.get(opts, :rotation, 0))
        view = Page.view_matrix(page, rotation)
        {w, h} = display_size(page, rotation)
        st = new(doc, page, Keyword.get(opts, :id_prefix, "p#{index}"), w, h)

        st = Interpreter.run_page(doc, page, &handle/2, st, ctm: view)
        st = close_all(st)

        st =
          if Keyword.get(opts, :annotations, true),
            do: draw_annotations(st, view, Keyword.get(opts, :skip_annotations, [])),
            else: st

        {vx0, vy0, vx1, vy1} = Keyword.get(opts, :viewbox) || {0, 0, w, h}
        vw = max(vx1 - vx0, 1)
        vh = max(vy1 - vy0, 1)

        background =
          case Keyword.get(opts, :background, "#fff") do
            nil ->
              []

            color ->
              [
                ~s(<rect width="),
                n(w),
                ~s(" height="),
                n(h),
                ~s(" fill="),
                escape(color),
                ~s("/>)
              ]
          end

        [
          ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="),
          n(vx0),
          " ",
          n(vy0),
          " ",
          n(vw),
          " ",
          n(vh),
          ~s(" width="),
          n(vw),
          ~s(" height="),
          n(vh),
          ~s(">),
          defs_markup(st),
          background,
          Enum.reverse(st.body),
          "</svg>"
        ]
    end
  end

  @doc """
  Renders one annotation's appearance as an SVG `<g>` fragment in display
  coordinates (points, top-left origin), or nil when it draws nothing.
  `annot_ref` is the annotation's reference or object number.
  """
  @spec render_annotation(Document.t(), non_neg_integer(), term(), keyword()) :: iodata() | nil
  def render_annotation(doc, index, annot_ref, opts \\ []) do
    num =
      case annot_ref do
        {:ref, n, _} -> n
        n when is_integer(n) -> n
      end

    with %Page{} = page <- Document.page(doc, index),
         {ref, annot} <-
           Enum.find(annotations(doc, page), fn {r, _} -> match?({:ref, ^num, _}, r) end) do
      rotation = normalize_rotation(Keyword.get(opts, :rotation, 0))
      view = Page.view_matrix(page, rotation)
      {w, h} = display_size(page, rotation)
      st = new(doc, page, Keyword.get(opts, :id_prefix, "p#{index}a#{num}"), w, h)
      st = draw_annotation(st, view, ref, annot, true)

      case st.body do
        [] -> nil
        body -> ["<g>", defs_markup(st), Enum.reverse(body), "</g>"]
      end
    else
      _ -> nil
    end
  end

  defp new(doc, page, prefix, w, h),
    do: %__MODULE__{doc: doc, page: page, prefix: prefix, w: w, h: h}

  defp normalize_rotation(r) when is_integer(r),
    do: r |> Integer.mod(360) |> div(90) |> Kernel.*(90)

  defp normalize_rotation(_), do: 0

  defp display_size(page, rotation) do
    {w, h} = Page.display_size(page)
    if rotation in [90, 270], do: {h, w}, else: {w, h}
  end

  defp defs_markup(%{defs: []}), do: []
  defp defs_markup(st), do: ["<defs>", Enum.reverse(st.defs), "</defs>"]

  # ---------------------------------------------------------------- events

  @doc false
  def handle({:path, %{path: path, fill: fill, stroke: stroke?, gs: gs}}, st) do
    st = sync(st, gs)
    {fill_attrs, st} = if fill, do: fill_attrs(st, gs, fill), else: {[~s( fill="none")], st}
    {stroke_attrs, st} = if stroke?, do: stroke_attrs(st, gs), else: {[], st}
    prec = precision(gs.ctm)

    el = [
      ~s(<path d="),
      path_d(path, prec),
      ~s(" transform="),
      matrix(gs.ctm),
      ~s("),
      fill_attrs,
      stroke_attrs,
      "/>"
    ]

    put(st, gs, el)
  end

  def handle({:glyph, %{font: %Font{type: "Type3"}}}, st), do: st
  def handle({:glyph, %{gs: %{render_mode: mode}}}, st) when mode in [3, 7], do: st
  def handle({:glyph, glyph}, st), do: draw_glyph(st, glyph)

  def handle({:image, %{image: image, gs: gs, resources: res}}, st) do
    st = sync(st, gs)
    draw_image(st, image, gs, res)
  end

  def handle({:shading, %{shading: sh, gs: gs, resources: res}}, st) do
    st = sync(st, gs)
    draw_shading(st, sh, gs, res)
  end

  def handle({:group_begin, %{gs: gs}}, st) do
    {clip_attr, st} =
      if blended?(gs) do
        st = st |> flush_run() |> sync_to([])
        chain_clip(st, Enum.drop(gs.clip, st.clip_base))
      else
        {[], st |> sync_clips_only(gs) |> flush_run()}
      end

    {mask_attr, st} =
      case gs.soft_mask do
        nil -> {[], st}
        sm -> mask_attr(st, sm)
      end

    opacity = if gs.fill_alpha < 1, do: [~s( opacity="), n(gs.fill_alpha), ~s(")], else: []
    open_tag = ["<g", opacity, clip_attr, mask_attr, blend(gs), ">"]
    frame = %{open: st.open, clip_base: st.clip_base}

    st = %{
      st
      | body: [open_tag | st.body],
        frames: [frame | st.frames],
        open: [],
        clip_base: length(gs.clip)
    }

    st
  end

  def handle({:group_end, _}, %{frames: [frame | rest]} = st) do
    st = st |> flush_run() |> close_open()
    %{st | body: ["</g>" | st.body], frames: rest, open: frame.open, clip_base: frame.clip_base}
  end

  def handle(_event, st), do: st

  defp emit(st, el), do: %{st | body: [el | st.body]}

  # ---------------------------------------------------------------- wrappers (clips and soft masks)

  defp wanted(st, gs) do
    clips = gs.clip |> Enum.drop(st.clip_base) |> Enum.map(&{:clip, &1})
    if gs.soft_mask, do: clips ++ [{:mask, gs.soft_mask}], else: clips
  end

  defp sync(st, gs) do
    want = if blended?(gs), do: [], else: wanted(st, gs)
    st = if st.run && want != st.open, do: flush_run(st), else: st
    sync_to(st, want)
  end

  defp sync_clips_only(st, gs) do
    want = gs.clip |> Enum.drop(st.clip_base) |> Enum.map(&{:clip, &1})
    sync_to(flush_run(st), want)
  end

  defp sync_to(%{open: open} = st, open), do: st

  defp sync_to(st, want) do
    k = common_prefix(st.open, want, 0)
    extra = length(st.open) - k
    st = %{st | body: List.duplicate("</g>", extra) ++ st.body, open: Enum.take(st.open, k)}

    want
    |> Enum.drop(k)
    |> Enum.reduce(st, fn wrapper, st ->
      {attr, st} = wrapper_attr(st, wrapper)
      %{st | body: [["<g", attr, ">"] | st.body], open: st.open ++ [wrapper]}
    end)
  end

  defp common_prefix([a | ra], [a | rb], k), do: common_prefix(ra, rb, k + 1)
  defp common_prefix(_, _, k), do: k

  # Blending is isolated by any ancestor with a clip-path or mask, so a
  # blended element gets its clips as one chained clipPath on a plain group.
  defp put(st, gs, el) do
    case wrap_attrs(st, gs) do
      {[], st} -> emit(st, el)
      {wrap, st} -> emit(st, ["<g", wrap, ">", el, "</g>"])
    end
  end

  defp wrap_attrs(st, gs) do
    if blended?(gs) do
      {clip, st} = chain_clip(st, Enum.drop(gs.clip, st.clip_base))
      {[clip, blend(gs)], st}
    else
      {[], st}
    end
  end

  defp blended?(%{blend: mode}), do: Map.has_key?(@blend_modes, mode)

  defp chain_clip(st, []), do: {[], st}

  defp chain_clip(st, entries) do
    {id, st} =
      Enum.reduce(entries, {nil, st}, fn {path, rule, ctm}, {parent, st} ->
        define(st, {:chain, parent, path, rule, ctm}, "c", fn id ->
          [
            ~s(<clipPath id="),
            id,
            ~s("),
            if(parent, do: [~s( clip-path="url(#), parent, ")\""], else: ""),
            ~s(><path d="),
            path_d(path, precision(ctm)),
            ~s(" transform="),
            matrix(ctm),
            ~s("),
            if(rule == :evenodd, do: ~s( clip-rule="evenodd"), else: ""),
            "/></clipPath>"
          ]
        end)
      end)

    {[~s( clip-path="url(#), id, ")\""], st}
  end

  defp close_open(st),
    do: %{st | body: List.duplicate("</g>", length(st.open)) ++ st.body, open: []}

  defp close_all(st) do
    st = st |> flush_run() |> close_open()

    Enum.reduce(st.frames, st, fn frame, st ->
      %{st | body: ["</g>" | List.duplicate("</g>", length(frame.open)) ++ st.body]}
    end)
    |> Map.merge(%{frames: [], clip_base: 0})
  end

  defp wrapper_attr(st, {:clip, {path, rule, ctm}}) do
    key = {:clip, path, rule, ctm}

    {id, st} =
      define(st, key, "c", fn id ->
        [
          ~s(<clipPath id="),
          id,
          ~s("><path d="),
          path_d(path, precision(ctm)),
          ~s(" transform="),
          matrix(ctm),
          ~s("),
          if(rule == :evenodd, do: ~s( clip-rule="evenodd"), else: ""),
          "/></clipPath>"
        ]
      end)

    {[~s( clip-path="url(#), id, ")\""], st}
  end

  defp wrapper_attr(st, {:mask, sm}), do: mask_attr(st, sm)

  # Defines something once; `build` gets the id and returns the markup.
  defp define(st, key, kind, build) do
    case Map.fetch(st.keys, key) do
      {:ok, id} ->
        {id, st}

      :error ->
        id = "#{st.prefix}#{kind}#{st.n}"
        st = %{st | n: st.n + 1, keys: Map.put(st.keys, key, id)}
        {markup, st} = run_build(build, id, st)
        {id, %{st | defs: [markup | st.defs]}}
    end
  end

  defp run_build(build, id, st) when is_function(build, 2), do: build.(id, st)
  defp run_build(build, id, st), do: {build.(id), st}

  # ---------------------------------------------------------------- soft masks

  defp mask_attr(st, sm) do
    key = {:smask, :erlang.phash2(Map.delete(sm, "__ctm")), sm["__ctm"]}

    {id, st} =
      define(st, key, "m", fn id, st ->
        doc = st.doc
        group = Document.resolve(doc, sm["G"])
        ctm = sm["__ctm"] || Matrix.identity()
        type = Document.resolve(doc, sm["S"])

        {content, st} =
          case group do
            %Stream{} = g when st.depth < @max_depth ->
              sub_render(st, fn st -> Interpreter.run_form(doc, g, ctm, &handle/2, st) end)

            _ ->
              {[], st}
          end

        backdrop =
          if type == "Alpha" do
            []
          else
            rgb = backdrop_color(doc, group, Document.resolve(doc, sm["BC"]))

            [
              ~s(<rect x="-10000" y="-10000" width="20000" height="20000" fill="),
              ColorSpace.hex(rgb),
              ~s("/>)
            ]
          end

        markup = [
          ~s(<mask id="),
          id,
          ~s(" maskUnits="userSpaceOnUse" x="-10000" y="-10000" width="20000" height="20000" style="mask-type:),
          if(type == "Alpha", do: "alpha", else: "luminance"),
          ~s(">),
          backdrop,
          content,
          "</mask>"
        ]

        {markup, st}
      end)

    {[~s( mask="url(#), id, ")\""], st}
  end

  defp backdrop_color(doc, %Stream{dict: dict}, bc) when is_list(bc) do
    cs =
      case Document.resolve(doc, dict["Group"]) do
        %{"CS" => cs} -> ColorSpace.parse(doc, cs)
        _ -> :gray
      end

    ColorSpace.to_rgb(cs, Enum.map(bc, &Document.resolve(doc, &1)))
  end

  defp backdrop_color(_doc, _group, _bc), do: {0.0, 0.0, 0.0}

  # Renders into a separate body, sharing defs; returns the inner markup.
  defp sub_render(st, fun) do
    saved = {st.body, st.open, st.frames, st.clip_base, st.run, st.depth}
    inner = %{st | body: [], open: [], frames: [], clip_base: 0, run: nil, depth: st.depth + 1}
    inner = inner |> fun.() |> close_all()
    {body, open, frames, clip_base, run, depth} = saved

    {Enum.reverse(inner.body),
     %{
       inner
       | body: body,
         open: open,
         frames: frames,
         clip_base: clip_base,
         run: run,
         depth: depth
     }}
  end

  # ---------------------------------------------------------------- paint

  defp fill_attrs(st, gs, rule) do
    {paint, st} = paint(st, gs, gs.fill, gs.fill_pattern)

    attrs = [
      ~s( fill="),
      paint,
      ~s("),
      if(rule == :evenodd, do: ~s( fill-rule="evenodd"), else: ""),
      if(gs.fill_alpha < 1, do: [~s( fill-opacity="), n(gs.fill_alpha), ~s(")], else: "")
    ]

    {attrs, st}
  end

  defp stroke_attrs(st, gs, width_scale \\ 1.0) do
    {paint, st} = paint(st, gs, gs.stroke, gs.stroke_pattern)
    lw = gs.line_width * width_scale
    device = gs.line_width * Matrix.scale_factor(gs.ctm)

    width =
      if device < 0.25,
        do: ~s( stroke-width="1" vector-effect="non-scaling-stroke"),
        else: [~s( stroke-width="), n4(lw), ~s(")]

    {dashes, phase} = gs.dash
    dashes = Enum.filter(dashes, &is_number/1)

    dash =
      if dashes != [] and Enum.all?(dashes, &(&1 >= 0)) and Enum.any?(dashes, &(&1 > 0)) do
        [
          ~s( stroke-dasharray="),
          dashes |> Enum.map(&n4(&1 * width_scale)) |> Enum.intersperse(" "),
          ~s("),
          if(phase != 0, do: [~s( stroke-dashoffset="), n4(phase * width_scale), ~s(")], else: "")
        ]
      else
        []
      end

    attrs = [
      ~s( stroke="),
      paint,
      ~s("),
      width,
      dash,
      case gs.line_cap do
        1 -> ~s( stroke-linecap="round")
        2 -> ~s( stroke-linecap="square")
        _ -> ""
      end,
      case gs.line_join do
        1 -> ~s( stroke-linejoin="round")
        2 -> ~s( stroke-linejoin="bevel")
        _ -> [~s( stroke-miterlimit="), n(max(gs.miter_limit, 1.0)), ~s(")]
      end,
      if(gs.stroke_alpha < 1, do: [~s( stroke-opacity="), n(gs.stroke_alpha), ~s(")], else: "")
    ]

    {attrs, st}
  end

  defp paint(st, _gs, rgb, nil), do: {ColorSpace.hex(rgb), st}

  defp paint(st, gs, rgb, {pattern, tint}) do
    doc = st.doc

    {dict, stream} =
      case Document.resolve(doc, pattern) do
        %Stream{dict: d} = s -> {d, s}
        %{} = d -> {d, nil}
        _ -> {nil, nil}
      end

    if dict == nil or st.depth >= @max_depth do
      {ColorSpace.hex(tint || rgb), st}
    else
      m = Matrix.from_pdf(Document.resolve(doc, dict["Matrix"]))
      base = Map.get(gs, :base_ctm) || gs.ctm
      transform = m |> Matrix.multiply(base) |> Matrix.multiply(Matrix.invert(gs.ctm))

      case Document.resolve(doc, dict["PatternType"]) do
        2 -> shading_paint(st, dict, transform, tint || rgb)
        1 when stream != nil -> tiling_paint(st, stream, dict, transform, tint || rgb)
        _ -> {ColorSpace.hex(tint || rgb), st}
      end
    end
  end

  defp shading_paint(st, dict, transform, fallback) do
    shading = Document.resolve(st.doc, dict["Shading"])
    key = {:shp, :erlang.phash2(shading), transform}

    case Map.fetch(st.keys, key) do
      {:ok, :none} ->
        {ColorSpace.hex(fallback), st}

      {:ok, id} ->
        {["url(#", id, ")"], st}

      :error ->
        id = "#{st.prefix}g#{st.n}"
        st = %{st | n: st.n + 1}

        case Shading.paint(st.doc, shading, transform, id) do
          {:gradient, markup} ->
            {["url(#", id, ")"],
             %{st | defs: [markup | st.defs], keys: Map.put(st.keys, key, id)}}

          {:triangles, [{_, rgb} | _]} ->
            {ColorSpace.hex(rgb), %{st | keys: Map.put(st.keys, key, :none)}}

          _ ->
            {ColorSpace.hex(fallback), %{st | keys: Map.put(st.keys, key, :none)}}
        end
    end
  end

  defp tiling_paint(st, stream, dict, transform, tint) do
    doc = st.doc
    get = &Document.resolve(doc, dict[&1])
    key = {:tile, :erlang.phash2(stream), transform, tint}

    {id, st} =
      define(st, key, "t", fn id, st ->
        {x0, y0, x1, y1} = Page.normalize_rect(get.("BBox"), doc) || {0, 0, 1, 1}
        xstep = abs(num(get.("XStep"), x1 - x0))
        ystep = abs(num(get.("YStep"), y1 - y0))
        xstep = if xstep == 0, do: max(x1 - x0, 1), else: xstep
        ystep = if ystep == 0, do: max(y1 - y0, 1), else: ystep
        resources = get.("Resources") || %{}
        content = Document.stream_data(doc, stream) || ""

        gs =
          if get.("PaintType") == 2,
            do: %GState{fill: tint, stroke: tint, fill_cs: :rgb, stroke_cs: :rgb},
            else: %GState{}

        {inner, st} =
          sub_render(st, fn st ->
            Interpreter.run(doc, content, resources, Matrix.identity(), &handle/2, st, gs: gs)
          end)

        tile_transform = Matrix.multiply(Matrix.translate(x0, y0), transform)

        markup = [
          ~s(<pattern id="),
          id,
          ~s(" patternUnits="userSpaceOnUse" x="0" y="0" width="),
          n4(xstep),
          ~s(" height="),
          n4(ystep),
          ~s(" patternTransform="),
          matrix(tile_transform),
          ~s("><g transform="translate(),
          n4(-x0),
          " ",
          n4(-y0),
          ")\">",
          inner,
          "</g></pattern>"
        ]

        {markup, st}
      end)

    {["url(#", id, ")"], st}
  end

  defp num(v, _default) when is_number(v), do: v / 1
  defp num(_, default), do: default / 1

  defp blend(%{blend: mode}) do
    case Map.fetch(@blend_modes, mode) do
      {:ok, css} -> [~s( style="mix-blend-mode:), css, ~s(")]
      :error -> ""
    end
  end

  # ---------------------------------------------------------------- glyphs

  defp draw_glyph(st, %{font: font, glyph: glyph, trm: trm, gs: gs}) do
    {code, _cid, uni, w0, _n} = glyph
    st = sync(st, gs)
    font_key = font.id || :erlang.phash2({font.base_font, font.type, font.encoding})
    gkey = {font_key, code}

    {outline_id, st} =
      case Map.fetch(st.glyphs, gkey) do
        {:ok, v} ->
          {v, st}

        :error ->
          v =
            case safe_outline(font, glyph) do
              nil -> :text
              [] -> :blank
              cmds -> {:path, cmds}
            end

          case v do
            {:path, cmds} ->
              id = "#{st.prefix}f#{st.n}"
              markup = [~s(<path id="), id, ~s(" d="), outline_d(cmds), ~s("/>)]

              {id,
               %{st | n: st.n + 1, glyphs: Map.put(st.glyphs, gkey, id), defs: [markup | st.defs]}}

            other ->
              {other, %{st | glyphs: Map.put(st.glyphs, gkey, other)}}
          end
      end

    case outline_id do
      :blank -> st
      :text -> draw_text_glyph(st, font, uni, w0, trm, gs)
      id -> draw_outline_glyph(st, id, trm, gs)
    end
  end

  defp safe_outline(font, glyph) do
    Font.glyph_outline(font, glyph)
  rescue
    _ -> nil
  end

  defp text_style(st, gs) do
    mode = gs.render_mode
    fill? = mode in [0, 2, 4, 6]
    stroke? = mode in [1, 2, 5, 6]
    {fill, st} = if fill?, do: paint(st, gs, gs.fill, gs.fill_pattern), else: {"none", st}
    {stroke, st} = if stroke?, do: paint(st, gs, gs.stroke, gs.stroke_pattern), else: {nil, st}

    style = [
      ~s( fill="),
      fill,
      ~s("),
      if(fill? and gs.fill_alpha < 1,
        do: [~s( fill-opacity="), n(gs.fill_alpha), ~s(")],
        else: ""
      ),
      if(stroke, do: [~s( stroke="), stroke, ~s(")], else: ""),
      if(stroke && gs.stroke_alpha < 1,
        do: [~s( stroke-opacity="), n(gs.stroke_alpha), ~s(")],
        else: ""
      )
    ]

    {wrap, st} = wrap_attrs(st, gs)
    # the wrap (clip + blend) travels in the style; ":" separates it for <text> runs
    {IO.iodata_to_binary([style, 0, wrap]), stroke != nil, st}
  end

  # Glyphs that share the linear part of their transform are drawn in one
  # group carrying it, each <use> placed by its origin in glyph units.
  defp draw_outline_glyph(st, id, trm, gs) do
    {style, stroke?, st} = text_style(st, gs)
    [a, b, c, d, e, f] = trm
    linear = {a, b, c, d}

    stroke_w =
      if stroke? do
        scale = Matrix.scale_factor(trm) / max(Matrix.scale_factor(gs.ctm), 1.0e-9)
        IO.iodata_to_binary([~s( stroke-width="), n4(gs.line_width / max(scale, 1.0e-9)), ~s(")])
      else
        ""
      end

    case st.run do
      %{type: :use, style: ^style, linear: ^linear, stroke_w: ^stroke_w, origin: {e0, f0}} = run
      when abs(a * d - b * c) > 1.0e-12 ->
        {dx, dy} = local(linear, e - e0, f - f0)
        %{st | run: %{run | items: [{id, dx, dy} | run.items]}}

      _ ->
        st = flush_run(st)

        %{
          st
          | run: %{
              type: :use,
              style: style,
              linear: linear,
              stroke_w: stroke_w,
              origin: {e, f},
              items: [{id, 0.0, 0.0}]
            }
        }
    end
  end

  defp draw_text_glyph(st, font, uni, w0, trm, gs) do
    chars = uni |> String.codepoints() |> Enum.reject(&(String.trim(&1) == ""))

    if chars == [] do
      st
    else
      {style, _stroke?, st} = text_style(st, gs)
      css = Font.css(font)
      [a, b, c, d, e, f] = trm
      linear = {a, b, c, d}

      case st.run do
        %{type: :text, style: ^style, css: ^css, linear: ^linear, origin: {e0, f0}} = run ->
          {dx, dy} = local(linear, e - e0, f - f0)

          if abs(dy) < 0.05 and dx > run.last_x - 0.01 do
            items = place(chars, dx, w0)
            %{st | run: %{run | items: [items | run.items], last_x: dx}}
          else
            start_text_run(flush_run(st), style, css, linear, {e, f}, chars, w0)
          end

        _ ->
          start_text_run(flush_run(st), style, css, linear, {e, f}, chars, w0)
      end
    end
  end

  defp start_text_run(st, style, css, linear, origin, chars, w0) do
    %{
      st
      | run: %{
          type: :text,
          style: style,
          css: css,
          linear: linear,
          origin: origin,
          items: [place(chars, 0.0, w0)],
          last_x: 0.0
        }
    }
  end

  defp place([ch], x, _w0), do: [{x, ch}]

  defp place(chars, x, w0) do
    step = w0 / length(chars)
    chars |> Enum.with_index() |> Enum.map(fn {ch, i} -> {x + i * step, ch} end)
  end

  defp local({a, b, c, d}, x, y) do
    det = a * d - b * c

    if abs(det) < 1.0e-12,
      do: {0.0, 0.0},
      else: {(d * x - c * y) / det, (-b * x + a * y) / det}
  end

  defp flush_run(%{run: nil} = st), do: st

  defp flush_run(%{run: %{type: :use} = run} = st) do
    [attrs, wrap] = :binary.split(run.style, <<0>>)
    {a, b, c, d} = run.linear
    {e, f} = run.origin

    uses =
      run.items
      |> Enum.reverse()
      |> Enum.map(fn {id, dx, dy} ->
        [
          ~s(<use href="#),
          id,
          ~s("),
          if(dx == 0, do: "", else: [~s( x="), n(dx), ~s(")]),
          if(dy == 0, do: "", else: [~s( y="), n(dy), ~s(")]),
          "/>"
        ]
      end)

    el = [
      "<g",
      attrs,
      run.stroke_w,
      ~s( transform="),
      matrix([a, b, c, d, e, f]),
      ~s(">),
      uses,
      "</g>"
    ]

    # clips are defined in page space: they go on an outer group without a transform
    el = if wrap == "", do: el, else: ["<g", wrap, ">", el, "</g>"]
    %{st | run: nil, body: [el | st.body]}
  end

  defp flush_run(%{run: %{type: :text} = run} = st) do
    {a, b, c, d} = run.linear
    {e, f} = run.origin
    s = 1 / @text_scale
    transform = [a * s, b * s, -c * s, -d * s, e, f]
    placed = run.items |> Enum.reverse() |> List.flatten()
    xs = placed |> Enum.map(fn {x, _} -> n(x * @text_scale) end) |> Enum.intersperse(" ")
    text = placed |> Enum.map(fn {_, ch} -> escape(ch) end)
    css = run.css
    [style, wrap] = :binary.split(run.style, <<0>>)

    el = [
      ~s(<text transform="),
      matrix(transform),
      ~s(" x="),
      xs,
      ~s(" y="0" font-size="),
      Integer.to_string(@text_scale),
      ~s(" font-family="),
      escape(css.family),
      ~s("),
      if(css.weight != "normal", do: [~s( font-weight="), css.weight, ~s(")], else: ""),
      if(css.style != "normal", do: [~s( font-style="), css.style, ~s(")], else: ""),
      style,
      ">",
      text,
      "</text>"
    ]

    el = if wrap == "", do: el, else: ["<g", wrap, ">", el, "</g>"]
    %{st | run: nil, body: [el | st.body]}
  end

  # ---------------------------------------------------------------- images

  defp draw_image(st, image, gs, resources) do
    st = flush_run(st)
    stencil? = image_mask?(st.doc, image)
    key = {:img, :erlang.phash2(image), if(stencil?, do: gs.fill, else: nil)}

    {entry, st} =
      case Map.fetch(st.images, key) do
        {:ok, entry} ->
          {entry, st}

        :error ->
          {entry, st} = prepare_image(st, image, resources, gs.fill)
          {entry, %{st | images: Map.put(st.images, key, entry)}}
      end

    transform = Matrix.multiply(@flip, gs.ctm)
    opacity = if gs.fill_alpha < 1, do: [~s( opacity="), n(gs.fill_alpha), ~s(")], else: ""

    case entry do
      {:image, id, mask_id} ->
        mask = if mask_id, do: [~s( mask="url(#), mask_id, ")\""], else: ""

        put(st, gs, [
          ~s(<use href="#),
          id,
          ~s(" transform="),
          matrix(transform),
          ~s("),
          opacity,
          mask,
          "/>"
        ])

      :placeholder ->
        put(st, gs, [
          ~s(<rect width="1" height="1" fill="#e6e6e6" transform="),
          matrix(transform),
          ~s("),
          opacity,
          "/>"
        ])

      :skip ->
        st
    end
  end

  defp image_mask?(doc, %Stream{dict: dict}), do: Document.resolve(doc, dict["ImageMask"]) == true
  defp image_mask?(_doc, %{dict: dict}), do: dict["ImageMask"] == true
  defp image_mask?(_, _), do: false

  defp prepare_image(st, image, resources, fill) do
    case Image.prepare(st.doc, image, resources, fill) do
      {:ok, img} ->
        id = "#{st.prefix}i#{st.n}"
        st = %{st | n: st.n + 1}

        markup = [
          ~s(<image id="),
          id,
          ~s(" width="1" height="1" preserveAspectRatio="none"),
          if(img.pixelated, do: ~s( style="image-rendering:pixelated"), else: ""),
          ~s( href="),
          img.href,
          ~s("/>)
        ]

        st = %{st | defs: [markup | st.defs]}

        case img.mask do
          nil ->
            {{:image, id, nil}, st}

          {type, href} ->
            mid = "#{st.prefix}k#{st.n}"

            mask = [
              ~s(<mask id="),
              mid,
              ~s(" maskUnits="userSpaceOnUse" x="0" y="0" width="1" height="1" style="mask-type:),
              Atom.to_string(type),
              ~s("><image width="1" height="1" preserveAspectRatio="none" href="),
              href,
              ~s("/></mask>)
            ]

            {{:image, id, mid}, %{st | n: st.n + 1, defs: [mask | st.defs]}}
        end

      {:placeholder, _} ->
        {:placeholder, st}

      :skip ->
        {:skip, st}
    end
  end

  # ---------------------------------------------------------------- shadings

  defp draw_shading(st, shading, gs, resources) do
    st = flush_run(st)
    id = "#{st.prefix}g#{st.n}"
    st = %{st | n: st.n + 1}
    opacity = if gs.fill_alpha < 1, do: [~s( opacity="), n(gs.fill_alpha), ~s(")], else: ""

    case Shading.paint(st.doc, shading, gs.ctm, id, resources) do
      {:gradient, markup} ->
        st = %{st | defs: [markup | st.defs]}

        put(st, gs, [
          ~s(<rect x="-1" y="-1" width="),
          n(st.w + 2),
          ~s(" height="),
          n(st.h + 2),
          ~s(" fill="url(#),
          id,
          ")\"",
          opacity,
          "/>"
        ])

      {:image, href, m} ->
        emit(st, [
          ~s(<image width="1" height="1" preserveAspectRatio="none" transform="),
          matrix(Matrix.multiply(@flip, m)),
          ~s(" href="),
          href,
          ~s("),
          opacity,
          "/>"
        ])

      {:triangles, tris} ->
        paths =
          Enum.map(tris, fn {[{x1, y1}, {x2, y2}, {x3, y3}], rgb} ->
            hex = ColorSpace.hex(rgb)

            [
              ~s(<path d="M),
              n(x1),
              " ",
              n(y1),
              "L",
              n(x2),
              " ",
              n(y2),
              "L",
              n(x3),
              " ",
              n(y3),
              ~s(Z" fill="),
              hex,
              ~s(" stroke="),
              hex,
              ~s(" stroke-width="0.3"/>)
            ]
          end)

        emit(st, ["<g", opacity, ">", paths, "</g>"])

      _ ->
        st
    end
  end

  # ---------------------------------------------------------------- annotations

  @doc false
  def annotations(doc, %Page{dict: dict}) do
    case Document.resolve(doc, dict["Annots"]) do
      list when is_list(list) ->
        Enum.flat_map(list, fn ref ->
          case Document.resolve(doc, ref) do
            %{} = annot -> [{ref, annot}]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp draw_annotations(st, view, skip) do
    skip = MapSet.new(skip)
    st = %{st | doc: with_field_appearances(st.doc, st.page)}

    st.doc
    |> annotations(st.page)
    |> Enum.reduce(st, fn {ref, annot}, st ->
      num = with {:ref, n, _} <- ref, do: n

      if MapSet.member?(skip, num), do: st, else: draw_annotation(st, view, ref, annot, false)
    end)
  end

  # form fields saved without an appearance are drawn from their value
  defp with_field_appearances(doc, page) do
    EmbedPdf.Forms.ensure_appearances(doc, page.index)
  rescue
    _ -> doc
  end

  defp draw_annotation(st, view, _ref, annot, force?) do
    doc = st.doc
    subtype = Document.resolve(doc, annot["Subtype"])
    flags = Document.resolve(doc, annot["F"]) || 0
    hidden? = Bitwise.band(flags, 2) != 0 or Bitwise.band(flags, 32) != 0

    cond do
      subtype == "Popup" ->
        st

      hidden? and not force? ->
        st

      true ->
        try do
          case AnnotationAppearance.appearance(doc, annot) do
            %Stream{} = ap ->
              case AnnotationAppearance.matrix(doc, annot, ap) do
                nil ->
                  st

                a ->
                  {inner, st} =
                    sub_render(st, fn st ->
                      Interpreter.run_form(doc, ap, Matrix.multiply(a, view), &handle/2, st)
                    end)

                  emit(st, ["<g>", inner, "</g>"])
              end

            nil ->
              case AnnotationAppearance.synthesize(doc, annot) do
                nil -> st
                markup -> emit(st, [~s(<g transform="), matrix(view), ~s(">), markup, "</g>"])
              end
          end
        rescue
          _ -> st
        end
    end
  end

  # ---------------------------------------------------------------- formatting

  defp path_d(cmds, prec) do
    Enum.map(cmds, fn
      {:m, x, y} ->
        ["M", f(x, prec), " ", f(y, prec)]

      {:l, x, y} ->
        ["L", f(x, prec), " ", f(y, prec)]

      {:c, x1, y1, x2, y2, x3, y3} ->
        [
          "C",
          f(x1, prec),
          " ",
          f(y1, prec),
          " ",
          f(x2, prec),
          " ",
          f(y2, prec),
          " ",
          f(x3, prec),
          " ",
          f(y3, prec)
        ]

      {:re, x, y, w, h} ->
        [
          "M",
          f(x, prec),
          " ",
          f(y, prec),
          "h",
          f(w, prec),
          "v",
          f(h, prec),
          "h",
          f(-w, prec),
          "Z"
        ]

      :h ->
        "Z"
    end)
  end

  defp outline_d(cmds) do
    Enum.map(cmds, fn
      {:move, x, y} ->
        ["M", f(x, 4), " ", f(y, 4)]

      {:line, x, y} ->
        ["L", f(x, 4), " ", f(y, 4)]

      {:curve, x1, y1, x2, y2, x, y} ->
        ["C", f(x1, 4), " ", f(y1, 4), " ", f(x2, 4), " ", f(y2, 4), " ", f(x, 4), " ", f(y, 4)]

      {:quad, x1, y1, x, y} ->
        ["Q", f(x1, 4), " ", f(y1, 4), " ", f(x, 4), " ", f(y, 4)]

      :close ->
        "Z"

      _ ->
        ""
    end)
  end

  # decimals so that the rounding error stays near 0.01 device points
  defp precision(ctm) do
    s = Matrix.scale_factor(ctm)

    cond do
      s <= 0.0 -> 2
      true -> (2 + :math.ceil(:math.log10(max(s, 1.0e-6)))) |> trunc() |> max(1) |> min(6)
    end
  end

  @pows {1, 10, 100, 1000, 10_000, 100_000, 1_000_000}

  defp f(x, d) when is_integer(x) and d >= 0, do: Integer.to_string(x)

  defp f(x, d) do
    pow = elem(@pows, d)
    r = round(x * pow)

    if rem(r, pow) == 0,
      do: Integer.to_string(div(r, pow)),
      else: :erlang.float_to_binary(r / pow, [:compact, decimals: d])
  end

  defp n(x), do: f(x, 3)
  defp n4(x), do: f(x, 4)

  defp matrix([a, b, c, d, e, g]),
    do: ["matrix(", sig(a), " ", sig(b), " ", sig(c), " ", sig(d), " ", sig(e), " ", sig(g), ")"]

  @doc false
  # 7 significant digits: matrices mix tiny scales with large translations
  def sig(x) when is_integer(x), do: Integer.to_string(x)

  def sig(x) do
    ax = abs(x)

    if ax < 1.0e-9 do
      "0"
    else
      d = (6 - :math.floor(:math.log10(ax))) |> trunc() |> max(0) |> min(15)
      r = Float.round(x / 1, d)

      if r == Float.round(r) and abs(r) < 1.0e15,
        do: r |> trunc() |> Integer.to_string(),
        else: :erlang.float_to_binary(r, [:compact, decimals: d])
    end
  end

  @doc false
  def escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> strip_invalid_xml()
  end

  defp strip_invalid_xml(s) do
    if String.valid?(s) do
      for <<cp::utf8 <- s>>, valid_xml_char?(cp), into: "", do: <<cp::utf8>>
    else
      ""
    end
  end

  defp valid_xml_char?(cp),
    do:
      cp in [9, 10, 13] or (cp >= 0x20 and cp <= 0xD7FF) or (cp >= 0xE000 and cp <= 0xFFFD) or
        cp >= 0x10000
end
