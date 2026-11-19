defmodule EmbedPdf.Annotation.Appearance do
  @moduledoc """
  Generates normal appearance streams (`/AP /N`) for annotations, so every
  viewer — and this library's renderer — draws them the same way.

  Appearances use the annotation's `rect` as their `BBox` with an identity
  `Matrix`, so they are drawn in user-space coordinates.
  """

  import EmbedPdf.Edit, only: [f: 1]

  alias EmbedPdf.{Annotation, Edit, Stamps}
  alias EmbedPdf.PDF.Stream

  @kappa 0.5522847498

  @doc "Builds the appearance stream, or nil for subtypes drawn without one."
  @spec build(Annotation.t()) :: Stream.t() | nil
  def build(%Annotation{rect: nil}), do: nil

  def build(%Annotation{} = a) do
    case draw(a) do
      nil ->
        nil

      {content, resources} ->
        {content, resources} = with_opacity(a, content, resources)
        Edit.form(a.rect, content, resources)
    end
  end

  defp with_opacity(%Annotation{subtype: :highlight}, content, resources),
    do: {content, resources}

  defp with_opacity(%Annotation{opacity: o}, content, resources) when is_number(o) and o < 1.0 do
    gs = %{"Type" => "ExtGState", "CA" => Edit.num(o), "ca" => Edit.num(o)}

    {["/GSa gs\n", content],
     Map.update(resources, "ExtGState", %{"GSa" => gs}, &Map.put(&1, "GSa", gs))}
  end

  defp with_opacity(_, content, resources), do: {content, resources}

  # ---------------------------------------------------------------- text markup

  defp draw(%Annotation{subtype: :highlight} = a) do
    color = a.color || {1.0, 0.92, 0.23}
    op = a.opacity || 1.0
    gs = %{"Type" => "ExtGState", "BM" => "Multiply", "CA" => Edit.num(op), "ca" => Edit.num(op)}

    rects =
      Enum.map(quads(a), fn {x0, y0, x1, y1} ->
        [f(x0), " ", f(y0), " ", f(x1 - x0), " ", f(y1 - y0), " re\n"]
      end)

    {["/GS0 gs\n", fill(color), rects, "f\n"], %{"ExtGState" => %{"GS0" => gs}}}
  end

  defp draw(%Annotation{subtype: :underline} = a) do
    lines =
      Enum.map(quads(a), fn {x0, y0, x1, y1} ->
        lw = max((y1 - y0) * 0.07, 0.75)
        y = y0 + lw * 1.5
        [f(lw), " w ", f(x0), " ", f(y), " m ", f(x1), " ", f(y), " l S\n"]
      end)

    {[stroke(a.color || {0.0, 0.0, 0.0}), lines], %{}}
  end

  defp draw(%Annotation{subtype: :strikeout} = a) do
    lines =
      Enum.map(quads(a), fn {x0, y0, x1, y1} ->
        lw = max((y1 - y0) * 0.07, 0.75)
        y = (y0 + y1) / 2
        [f(lw), " w ", f(x0), " ", f(y), " m ", f(x1), " ", f(y), " l S\n"]
      end)

    {[stroke(a.color || {0.9, 0.1, 0.1}), lines], %{}}
  end

  defp draw(%Annotation{subtype: :squiggly} = a) do
    lines =
      Enum.map(quads(a), fn {x0, y0, x1, y1} ->
        h = y1 - y0
        lw = max(h * 0.05, 0.6)
        amp = max(h * 0.06, 1.0)
        step = max(h * 0.12, 2.0)
        base = y0 + amp + lw
        n = max(trunc((x1 - x0) / step), 1)

        pts =
          for i <- 0..n do
            y = if rem(i, 2) == 0, do: base - amp, else: base + amp
            [f(min(x0 + i * step, x1)), " ", f(y), if(i == 0, do: " m ", else: " l ")]
          end

        ["1 j ", f(lw), " w ", pts, "S\n"]
      end)

    {[stroke(a.color || {0.2, 0.6, 0.2}), lines], %{}}
  end

  # ---------------------------------------------------------------- drawing

  defp draw(%Annotation{subtype: :ink} = a) do
    paths =
      Enum.map(a.ink_list, fn
        [{x, y}] ->
          [f(x), " ", f(y), " m ", f(x + 0.01), " ", f(y), " l S\n"]

        [{x, y} | rest] ->
          [
            f(x),
            " ",
            f(y),
            " m ",
            Enum.map(rest, fn {px, py} -> [f(px), " ", f(py), " l "] end),
            "S\n"
          ]

        [] ->
          []
      end)

    {[
       "1 J 1 j ",
       f(a.border_width || 1.0),
       " w\n",
       dash(a),
       stroke(a.color || {0.0, 0.0, 0.0}),
       paths
     ], %{}}
  end

  defp draw(%Annotation{subtype: :square} = a) do
    {x0, y0, x1, y1} = a.rect
    lw = a.border_width || 1.0
    h = lw / 2
    w = max(x1 - x0 - lw, 0)
    ht = max(y1 - y0 - lw, 0)

    {[
       f(lw),
       " w\n",
       dash(a),
       stroke(a.color || {0.0, 0.0, 0.0}),
       maybe_fill(a.interior_color),
       f(x0 + h),
       " ",
       f(y0 + h),
       " ",
       f(w),
       " ",
       f(ht),
       " re ",
       paint(a, lw),
       "\n"
     ], %{}}
  end

  defp draw(%Annotation{subtype: :circle} = a) do
    {x0, y0, x1, y1} = a.rect
    lw = a.border_width || 1.0
    h = lw / 2
    path = ellipse(x0 + h, y0 + h, x1 - h, y1 - h)

    {[
       f(lw),
       " w\n",
       dash(a),
       stroke(a.color || {0.0, 0.0, 0.0}),
       maybe_fill(a.interior_color),
       path,
       paint(a, lw),
       "\n"
     ], %{}}
  end

  defp draw(%Annotation{subtype: :line, line: {x1, y1, x2, y2}} = a) do
    lw = a.border_width || 1.0
    {s, e} = a.line_endings
    color = a.color || {0.0, 0.0, 0.0}

    {[
       "1 j ",
       f(lw),
       " w\n",
       dash(a),
       stroke(color),
       fill(a.interior_color || color),
       f(x1),
       " ",
       f(y1),
       " m ",
       f(x2),
       " ",
       f(y2),
       " l S\n",
       "[] 0 d\n",
       ending(s, {x1, y1}, {x2, y2}, lw, a.interior_color),
       ending(e, {x2, y2}, {x1, y1}, lw, a.interior_color)
     ], %{}}
  end

  defp draw(%Annotation{subtype: :polygon, vertices: [{x, y} | rest]} = a) do
    lw = a.border_width || 1.0

    {[
       "1 j ",
       f(lw),
       " w\n",
       dash(a),
       stroke(a.color || {0.0, 0.0, 0.0}),
       maybe_fill(a.interior_color),
       f(x),
       " ",
       f(y),
       " m ",
       Enum.map(rest, fn {px, py} -> [f(px), " ", f(py), " l "] end),
       "h ",
       paint(a, lw),
       "\n"
     ], %{}}
  end

  defp draw(%Annotation{subtype: :polyline, vertices: [{x, y} | rest] = vs} = a) do
    lw = a.border_width || 1.0
    {s, e} = a.line_endings
    color = a.color || {0.0, 0.0, 0.0}

    ends =
      case vs do
        [p1, p2 | _] ->
          [pn1, pn] = Enum.take(vs, -2)
          [ending(s, p1, p2, lw, a.interior_color), ending(e, pn, pn1, lw, a.interior_color)]

        _ ->
          []
      end

    {[
       "1 j ",
       f(lw),
       " w\n",
       dash(a),
       stroke(color),
       fill(a.interior_color || color),
       f(x),
       " ",
       f(y),
       " m ",
       Enum.map(rest, fn {px, py} -> [f(px), " ", f(py), " l "] end),
       "S\n[] 0 d\n",
       ends
     ], %{}}
  end

  # ---------------------------------------------------------------- text

  defp draw(%Annotation{subtype: :free_text} = a) do
    {x0, y0, x1, y1} = a.rect
    size = a.font_size || 12
    {res, base} = Edit.std_font(a.font_family || :helvetica)
    lw = a.border_width || 0.0
    pad = 2 + lw
    width = max(x1 - x0 - 2 * pad, 1)
    lines = Edit.wrap(a.contents || "", base, size, width)
    leading = size * 1.17
    ascent = size * 0.78

    bg =
      if a.color,
        do: [fill(a.color), f(x0), " ", f(y0), " ", f(x1 - x0), " ", f(y1 - y0), " re f\n"],
        else: []

    border =
      if lw > 0,
        do: [
          stroke(a.interior_color || a.font_color || {0.0, 0.0, 0.0}),
          f(lw),
          " w ",
          dash(a),
          f(x0 + lw / 2),
          " ",
          f(y0 + lw / 2),
          " ",
          f(x1 - x0 - lw),
          " ",
          f(y1 - y0 - lw),
          " re S\n"
        ],
        else: []

    text =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        w = Edit.text_width(line, base, size)

        x =
          case a.text_align do
            :center -> x0 + pad + (width - w) / 2
            :right -> x1 - pad - w
            _ -> x0 + pad
          end

        y = y1 - pad - ascent - i * leading
        ["1 0 0 1 ", f(x), " ", f(y), " Tm ", Edit.tj(line), "\n"]
      end)

    {[
       bg,
       border,
       "q ",
       f(x0 + lw),
       " ",
       f(y0 + lw),
       " ",
       f(max(x1 - x0 - 2 * lw, 0)),
       " ",
       f(max(y1 - y0 - 2 * lw, 0)),
       " re W n\nBT /",
       res,
       " ",
       f(size),
       " Tf ",
       fill(a.font_color || {0.0, 0.0, 0.0}),
       text,
       "ET Q\n"
     ], %{"Font" => %{res => Edit.std_font_dict(base)}}}
  end

  defp draw(%Annotation{subtype: :stamp} = a) do
    stamp = Stamps.get(a.icon)
    color = a.color || (stamp && stamp.color) || {0.09412, 0.1451, 0.39215}
    label = (stamp && stamp.label) || a.subject || a.icon || a.contents || "Stamp"

    rotated(a, fn w, h ->
      kind = stamp && stamp.kind

      case kind do
        :check -> check_icon(w, h, color)
        :cross -> cross_icon(w, h, color)
        _ -> stamp_box(w, h, String.upcase(label), color, kind)
      end
    end)
  end

  defp draw(%Annotation{subtype: :text} = a) do
    {x0, y0, x1, y1} = a.rect
    sx = (x1 - x0) / 20
    sy = (y1 - y0) / 20
    color = a.color || {1.0, 0.82, 0.0}
    p = fn x, y -> [f(x0 + x * sx), " ", f(y0 + y * sy)] end

    bubble = [
      p.(2, 19),
      " m ",
      p.(18, 19),
      " l ",
      p.(19, 18),
      " ",
      p.(19, 18),
      " ",
      p.(19, 17),
      " c ",
      p.(19, 7),
      " l ",
      p.(19, 6),
      " ",
      p.(19, 6),
      " ",
      p.(18, 6),
      " c ",
      p.(9, 6),
      " l ",
      p.(4, 1),
      " l ",
      p.(5, 6),
      " l ",
      p.(2, 6),
      " l ",
      p.(1, 6),
      " ",
      p.(1, 6),
      " ",
      p.(1, 7),
      " c ",
      p.(1, 17),
      " l ",
      p.(1, 18),
      " ",
      p.(1, 18),
      " ",
      p.(2, 19),
      " c h B\n"
    ]

    lines = for y <- [15, 12, 9], do: [p.(4, y), " m ", p.(16, y), " l S\n"]

    {["1 j 0.6 w ", fill(color), stroke({0.25, 0.25, 0.25}), bubble, "0.8 w ", lines], %{}}
  end

  defp draw(%Annotation{subtype: :redact} = a) do
    rects = if a.quad_points != [], do: a.quad_points, else: [a.rect]
    color = a.color || {1.0, 0.0, 0.0}
    lw = max(a.border_width || 1.0, 1.0)

    boxes =
      Enum.map(rects, fn {x0, y0, x1, y1} ->
        [
          f(x0 + lw / 2),
          " ",
          f(y0 + lw / 2),
          " ",
          f(x1 - x0 - lw),
          " ",
          f(y1 - y0 - lw),
          " re S\n"
        ]
      end)

    {[f(lw), " w ", stroke(color), boxes], %{}}
  end

  defp draw(%Annotation{subtype: :caret} = a) do
    {x0, y0, x1, y1} = a.rect
    w = x1 - x0
    h = y1 - y0
    mx = x0 + w / 2

    {[
       fill(a.color || {0.0, 0.3, 0.9}),
       f(x0),
       " ",
       f(y0),
       " m ",
       f(x0 + w * 0.35),
       " ",
       f(y0 + h * 0.3),
       " ",
       f(mx),
       " ",
       f(y0 + h * 0.6),
       " ",
       f(mx),
       " ",
       f(y1),
       " c ",
       f(mx),
       " ",
       f(y0 + h * 0.6),
       " ",
       f(x1 - w * 0.35),
       " ",
       f(y0 + h * 0.3),
       " ",
       f(x1),
       " ",
       f(y0),
       " c h f\n"
     ], %{}}
  end

  defp draw(%Annotation{subtype: :file_attachment} = a) do
    {x0, y0, x1, y1} = a.rect
    sx = (x1 - x0) / 14
    sy = (y1 - y0) / 20
    p = fn x, y -> [f(x0 + x * sx), " ", f(y0 + y * sy)] end

    clip = [
      p.(10, 6),
      " m ",
      p.(10, 3),
      " l ",
      p.(10, 1),
      " ",
      p.(8.5, 0.5),
      " ",
      p.(7, 0.5),
      " c ",
      p.(5.5, 0.5),
      " ",
      p.(4, 1),
      " ",
      p.(4, 3),
      " c ",
      p.(4, 16),
      " l ",
      p.(4, 18.5),
      " ",
      p.(5.5, 19.5),
      " ",
      p.(7.5, 19.5),
      " c ",
      p.(9.5, 19.5),
      " ",
      p.(11, 18.5),
      " ",
      p.(11, 16),
      " c ",
      p.(11, 5),
      " l ",
      p.(11, 4),
      " ",
      p.(10.5, 3.5),
      " ",
      p.(9.8, 3.5),
      " c ",
      p.(9, 3.5),
      " ",
      p.(8.5, 4),
      " ",
      p.(8.5, 5),
      " c ",
      p.(8.5, 14),
      " l S\n"
    ]

    {["1 J 1 j 1.2 w ", stroke(a.color || {0.2, 0.2, 0.2}), clip], %{}}
  end

  defp draw(%Annotation{subtype: :link} = a) do
    {x0, y0, x1, y1} = a.rect
    lw = a.border_width || 0.0

    if lw > 0 do
      {[
         f(lw),
         " w ",
         dash(a),
         stroke(a.color || {0.0, 0.0, 1.0}),
         f(x0 + lw / 2),
         " ",
         f(y0 + lw / 2),
         " ",
         f(x1 - x0 - lw),
         " ",
         f(y1 - y0 - lw),
         " re S\n"
       ], %{}}
    else
      {[], %{}}
    end
  end

  defp draw(_), do: nil

  # ---------------------------------------------------------------- stamps

  # Draws `fun.(w, h)` (content for a w×h box at the origin) rotated
  # within the annotation rect.
  defp rotated(%Annotation{rect: {x0, y0, x1, y1}, rotation: rot}, fun) do
    bw = x1 - x0
    bh = y1 - y0
    rad = (rot || 0) * :math.pi() / 180
    c = abs(:math.cos(rad))
    s = abs(:math.sin(rad))

    {w, h} =
      cond do
        s < 1.0e-6 -> {bw, bh}
        c < 1.0e-6 -> {bh, bw}
        abs(c * c - s * s) < 1.0e-3 -> {bw / (c + s), bh / (c + s) * 0.4}
        true -> {(bw * c - bh * s) / (c * c - s * s), (bh * c - bw * s) / (c * c - s * s)}
      end

    w = max(w, 1.0)
    h = max(h, 1.0)
    {content, res} = fun.(w, h)
    cos = :math.cos(rad)
    sin = :math.sin(rad)
    cx = x0 + bw / 2
    cy = y0 + bh / 2
    # translate to centre, rotate counter-clockwise, then offset to the box origin
    tx = cx - (cos * w / 2 - sin * h / 2)
    ty = cy - (sin * w / 2 + cos * h / 2)

    {[
       "q ",
       f(cos),
       " ",
       f(sin),
       " ",
       f(-sin),
       " ",
       f(cos),
       " ",
       f(tx),
       " ",
       f(ty),
       " cm\n",
       content,
       "Q\n"
     ], res}
  end

  defp stamp_box(w, h, label, color, kind) do
    lw = max(min(h * 0.07, 4.0), 1.0)
    r = min(h * 0.22, w * 0.2)
    {res, base} = Edit.std_font(:helvetica, true)
    pad = r + lw
    size = min(h * 0.52, (w - 2 * pad) / max(Edit.text_width(label, base, 1), 0.01))
    size = max(size, 1.0)
    tw = Edit.text_width(label, base, size)
    tx = (w - tw) / 2
    ty = (h - size * 0.72) / 2

    bg =
      if kind == :sign,
        do: [fill({1.0, 0.97, 0.8}), rounded(lw / 2, lw / 2, w - lw, h - lw, r), "f\n"],
        else: []

    {[
       bg,
       f(lw),
       " w ",
       stroke(color),
       rounded(lw / 2, lw / 2, w - lw, h - lw, r),
       "S\n",
       "BT /",
       res,
       " ",
       f(size),
       " Tf ",
       fill(color),
       "1 0 0 1 ",
       f(tx),
       " ",
       f(ty),
       " Tm ",
       Edit.tj(label),
       " ET\n"
     ], %{"Font" => %{res => Edit.std_font_dict(base)}}}
  end

  defp check_icon(w, h, color) do
    lw = max(min(w, h) * 0.14, 1.0)

    {[
       "1 J 1 j ",
       f(lw),
       " w ",
       stroke(color),
       f(w * 0.15),
       " ",
       f(h * 0.52),
       " m ",
       f(w * 0.4),
       " ",
       f(h * 0.2),
       " l ",
       f(w * 0.85),
       " ",
       f(h * 0.85),
       " l S\n"
     ], %{}}
  end

  defp cross_icon(w, h, color) do
    lw = max(min(w, h) * 0.14, 1.0)

    {[
       "1 J ",
       f(lw),
       " w ",
       stroke(color),
       f(w * 0.18),
       " ",
       f(h * 0.18),
       " m ",
       f(w * 0.82),
       " ",
       f(h * 0.82),
       " l S ",
       f(w * 0.18),
       " ",
       f(h * 0.82),
       " m ",
       f(w * 0.82),
       " ",
       f(h * 0.18),
       " l S\n"
     ], %{}}
  end

  defp rounded(x, y, w, h, r) do
    r = r |> min(w / 2) |> min(h / 2) |> max(0)
    k = r * @kappa

    [
      f(x + r),
      " ",
      f(y),
      " m ",
      f(x + w - r),
      " ",
      f(y),
      " l ",
      f(x + w - r + k),
      " ",
      f(y),
      " ",
      f(x + w),
      " ",
      f(y + r - k),
      " ",
      f(x + w),
      " ",
      f(y + r),
      " c ",
      f(x + w),
      " ",
      f(y + h - r),
      " l ",
      f(x + w),
      " ",
      f(y + h - r + k),
      " ",
      f(x + w - r + k),
      " ",
      f(y + h),
      " ",
      f(x + w - r),
      " ",
      f(y + h),
      " c ",
      f(x + r),
      " ",
      f(y + h),
      " l ",
      f(x + r - k),
      " ",
      f(y + h),
      " ",
      f(x),
      " ",
      f(y + h - r + k),
      " ",
      f(x),
      " ",
      f(y + h - r),
      " c ",
      f(x),
      " ",
      f(y + r),
      " l ",
      f(x),
      " ",
      f(y + r - k),
      " ",
      f(x + r - k),
      " ",
      f(y),
      " ",
      f(x + r),
      " ",
      f(y),
      " c h "
    ]
  end

  # ---------------------------------------------------------------- helpers

  defp quads(%Annotation{quad_points: [], rect: rect}), do: [rect]
  defp quads(%Annotation{quad_points: q}), do: q

  defp fill(nil), do: []
  defp fill({r, g, b}), do: [f(Edit.num(r)), " ", f(Edit.num(g)), " ", f(Edit.num(b)), " rg\n"]
  defp stroke({r, g, b}), do: [f(Edit.num(r)), " ", f(Edit.num(g)), " ", f(Edit.num(b)), " RG\n"]
  defp maybe_fill(nil), do: []
  defp maybe_fill(c), do: fill(c)

  defp paint(%Annotation{interior_color: nil}, _lw), do: "S"
  defp paint(%Annotation{}, lw) when lw <= 0, do: "f"
  defp paint(%Annotation{}, _lw), do: "B"

  defp dash(%Annotation{border_style: :dashed, dash: d}) do
    d = if d in [nil, []], do: [3.0], else: d
    ["[", Enum.map_join(d, " ", &f/1), "] 0 d\n"]
  end

  defp dash(_), do: []

  defp ellipse(x0, y0, x1, y1) do
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2
    rx = max((x1 - x0) / 2, 0)
    ry = max((y1 - y0) / 2, 0)
    kx = rx * @kappa
    ky = ry * @kappa

    [
      f(cx + rx),
      " ",
      f(cy),
      " m ",
      f(cx + rx),
      " ",
      f(cy + ky),
      " ",
      f(cx + kx),
      " ",
      f(cy + ry),
      " ",
      f(cx),
      " ",
      f(cy + ry),
      " c ",
      f(cx - kx),
      " ",
      f(cy + ry),
      " ",
      f(cx - rx),
      " ",
      f(cy + ky),
      " ",
      f(cx - rx),
      " ",
      f(cy),
      " c ",
      f(cx - rx),
      " ",
      f(cy - ky),
      " ",
      f(cx - kx),
      " ",
      f(cy - ry),
      " ",
      f(cx),
      " ",
      f(cy - ry),
      " c ",
      f(cx + kx),
      " ",
      f(cy - ry),
      " ",
      f(cx + rx),
      " ",
      f(cy - ky),
      " ",
      f(cx + rx),
      " ",
      f(cy),
      " c h "
    ]
  end

  @doc false
  # Line ending at `tip`, pointing away from `from`.
  def ending(:none, _tip, _from, _lw, _ic), do: []

  def ending(kind, {tx, ty} = tip, {fx, fy}, lw, ic) do
    len = max(lw * 4.5, 6.0)
    dx = tx - fx
    dy = ty - fy
    d = max(:math.sqrt(dx * dx + dy * dy), 1.0e-6)
    ux = dx / d
    uy = dy / d
    # perpendicular
    px = -uy
    py = ux
    half = len * 0.45
    back = fn l -> {tx - ux * l, ty - uy * l} end
    pt = fn {x, y} -> [f(x), " ", f(y)] end
    {bx, by} = back.(len)
    left = {bx + px * half, by + py * half}
    right = {bx - px * half, by - py * half}
    fill_op = if ic, do: "b", else: "s"

    case kind do
      :open_arrow ->
        [pt.(left), " m ", pt.(tip), " l ", pt.(right), " l S\n"]

      :closed_arrow ->
        [pt.(left), " m ", pt.(tip), " l ", pt.(right), " l h b\n"]

      :r_open_arrow ->
        {fx2, fy2} = {tx + ux * len, ty + uy * len}

        [
          pt.({fx2 + px * half, fy2 + py * half}),
          " m ",
          pt.(tip),
          " l ",
          pt.({fx2 - px * half, fy2 - py * half}),
          " l S\n"
        ]

      :r_closed_arrow ->
        {fx2, fy2} = {tx + ux * len, ty + uy * len}

        [
          pt.({fx2 + px * half, fy2 + py * half}),
          " m ",
          pt.(tip),
          " l ",
          pt.({fx2 - px * half, fy2 - py * half}),
          " l h b\n"
        ]

      :butt ->
        [
          pt.({tx + px * half, ty + py * half}),
          " m ",
          pt.({tx - px * half, ty - py * half}),
          " l S\n"
        ]

      :slash ->
        c = :math.cos(:math.pi() / 6)
        s = :math.sin(:math.pi() / 6)
        # 60° from the line direction
        sx = px * c + ux * s
        sy = py * c + uy * s

        [
          pt.({tx + sx * half, ty + sy * half}),
          " m ",
          pt.({tx - sx * half, ty - sy * half}),
          " l S\n"
        ]

      :circle ->
        r = len * 0.35
        [ellipse(tx - r, ty - r, tx + r, ty + r), fill_op, "\n"]

      :square ->
        r = len * 0.35
        [f(tx - r), " ", f(ty - r), " ", f(2 * r), " ", f(2 * r), " re ", fill_op, "\n"]

      :diamond ->
        r = len * 0.45

        [
          pt.({tx + ux * r, ty + uy * r}),
          " m ",
          pt.({tx + px * r, ty + py * r}),
          " l ",
          pt.({tx - ux * r, ty - uy * r}),
          " l ",
          pt.({tx - px * r, ty - py * r}),
          " l h ",
          fill_op,
          "\n"
        ]

      _ ->
        []
    end
  end
end
