defmodule EmbedPdf.Render.AnnotationAppearance do
  @moduledoc """
  Annotation appearances (ISO 32000-1, 12.5.5): finding the normal
  appearance stream and its placement matrix, and drawing a reasonable SVG
  stand-in for annotations that come without one.

  `synthesize/2` returns SVG markup in PDF user space (y up); callers wrap
  it in the page's view transform.
  """

  alias EmbedPdf.Font.{AFM, GlyphList}
  alias EmbedPdf.PDF.{Document, Page, Stream, TextString}
  alias EmbedPdf.Render.{ColorSpace, Matrix}

  @doc "The normal appearance stream (respecting `/AS`), or nil."
  @spec appearance(Document.t(), map()) :: Stream.t() | nil
  def appearance(doc, annot) do
    case Document.get(doc, Document.get(doc, annot, "AP"), "N") do
      %Stream{} = s ->
        s

      %{} = states ->
        state = Document.resolve(doc, annot["AS"])

        case state && Document.resolve(doc, states[state]) do
          %Stream{} = s -> s
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  The matrix mapping the appearance's form space (after its own `/Matrix`)
  onto the annotation's `/Rect` in user space, or nil when degenerate.
  """
  @spec matrix(Document.t(), map(), Stream.t()) :: Matrix.t() | nil
  def matrix(doc, annot, %Stream{dict: dict}) do
    with {rx0, ry0, rx1, ry1} <- Page.normalize_rect(Document.resolve(doc, annot["Rect"]), doc) do
      bbox = Page.normalize_rect(Document.resolve(doc, dict["BBox"]), doc) || {rx0, ry0, rx1, ry1}
      m = Matrix.from_pdf(Document.resolve(doc, dict["Matrix"]))
      {bx0, by0, bx1, by1} = Matrix.transform_rect(m, bbox)
      sx = if bx1 - bx0 > 1.0e-9, do: (rx1 - rx0) / (bx1 - bx0), else: 1.0
      sy = if by1 - by0 > 1.0e-9, do: (ry1 - ry0) / (by1 - by0), else: 1.0
      [sx, 0.0, 0.0, sy, rx0 - bx0 * sx, ry0 - by0 * sy]
    else
      _ -> nil
    end
  end

  # ---------------------------------------------------------------- synthesized appearances

  @doc "SVG markup (user space) for an annotation without an appearance stream, or nil."
  @spec synthesize(Document.t(), map()) :: iodata() | nil
  def synthesize(doc, annot) do
    get = &Document.resolve(doc, annot[&1])
    rect = Page.normalize_rect(get.("Rect"), doc)
    subtype = get.("Subtype")

    a = %{
      doc: doc,
      get: get,
      rect: rect,
      color: color(get.("C")),
      interior: color(get.("IC")),
      opacity: opacity(get.("CA")),
      width: border_width(doc, annot),
      dash: border_dash(doc, annot)
    }

    if rect == nil and subtype not in ["Ink", "Line", "Polygon", "PolyLine"] do
      nil
    else
      draw(subtype, a)
    end
  end

  defp draw("Highlight", a) do
    quads(a)
    |> Enum.map(fn q ->
      [
        ~s(<path d="),
        quad_d(q),
        ~s(" fill="),
        hex(a.color || {1.0, 1.0, 0.0}),
        ~s(" fill-opacity="),
        n(a.opacity),
        ~s(" style="mix-blend-mode:multiply"/>)
      ]
    end)
  end

  defp draw(kind, a) when kind in ["Underline", "StrikeOut", "Squiggly"] do
    color = hex(a.color || {0.0, 0.0, 0.0})

    quads(a)
    |> Enum.map(fn [{x1, y1}, {x2, y2}, {x3, y3}, {x4, y4}] ->
      h = :math.sqrt((x1 - x3) * (x1 - x3) + (y1 - y3) * (y1 - y3))
      lw = max(h / 14, 0.5)

      case kind do
        "Underline" ->
          line(
            {x3 + (x1 - x3) * 0.08, y3 + (y1 - y3) * 0.08},
            {x4 + (x2 - x4) * 0.08, y4 + (y2 - y4) * 0.08},
            color,
            lw,
            a.opacity
          )

        "StrikeOut" ->
          line(
            {(x1 + x3) / 2, (y1 + y3) / 2},
            {(x2 + x4) / 2, (y2 + y4) / 2},
            color,
            lw,
            a.opacity
          )

        "Squiggly" ->
          squiggle({x3, y3}, {x4, y4}, h, color, lw, a.opacity)
      end
    end)
  end

  defp draw("Square", a) do
    {x0, y0, x1, y1} = a.rect
    i = a.width / 2

    [
      ~s(<rect x="),
      n(x0 + i),
      ~s(" y="),
      n(y0 + i),
      ~s(" width="),
      n(max(x1 - x0 - a.width, 0)),
      ~s(" height="),
      n(max(y1 - y0 - a.width, 0)),
      ~s("),
      shape_style(a),
      "/>"
    ]
  end

  defp draw("Circle", a) do
    {x0, y0, x1, y1} = a.rect
    i = a.width / 2

    [
      ~s(<ellipse cx="),
      n((x0 + x1) / 2),
      ~s(" cy="),
      n((y0 + y1) / 2),
      ~s(" rx="),
      n(max((x1 - x0) / 2 - i, 0)),
      ~s(" ry="),
      n(max((y1 - y0) / 2 - i, 0)),
      ~s("),
      shape_style(a),
      "/>"
    ]
  end

  defp draw("Line", a) do
    case nums(a.get.("L")) do
      [x1, y1, x2, y2 | _] ->
        [
          ~s(<path d="M),
          n(x1),
          " ",
          n(y1),
          "L",
          n(x2),
          " ",
          n(y2),
          ~s("),
          stroke_style(a),
          ~s( fill="none"/>),
          line_endings(a, {x1, y1}, {x2, y2})
        ]

      _ ->
        nil
    end
  end

  defp draw("Ink", a) do
    case a.get.("InkList") do
      list when is_list(list) ->
        paths =
          list
          |> Enum.map(&Document.resolve(a.doc, &1))
          |> Enum.map(&nums/1)
          |> Enum.reject(&(length(&1) < 2))
          |> Enum.map(fn pts -> polyline_d(pts, false) end)

        [
          ~s(<path d="),
          paths,
          ~s(" fill="none" stroke-linecap="round" stroke-linejoin="round"),
          stroke_style(a),
          "/>"
        ]

      _ ->
        nil
    end
  end

  defp draw(kind, a) when kind in ["Polygon", "PolyLine"] do
    pts = nums(a.get.("Vertices"))

    if length(pts) >= 4 do
      closed? = kind == "Polygon"

      fill =
        if closed? and a.interior,
          do: [~s( fill="), hex(a.interior), ~s(")],
          else: ~s( fill="none")

      [
        ~s(<path d="),
        polyline_d(pts, closed?),
        ~s("),
        fill,
        ~s( stroke-linejoin="round"),
        stroke_style(a),
        "/>"
      ]
    end
  end

  defp draw("FreeText", a) do
    {x0, y0, x1, y1} = a.rect
    {size, rgb} = default_appearance(a.get.("DA"))
    text = a.get.("Contents") |> to_text()
    align = a.get.("Q") || 0

    border =
      if a.width > 0 and a.get.("BS") != nil do
        [
          ~s(<rect x="),
          n(x0 + a.width / 2),
          ~s(" y="),
          n(y0 + a.width / 2),
          ~s(" width="),
          n(max(x1 - x0 - a.width, 0)),
          ~s(" height="),
          n(max(y1 - y0 - a.width, 0)),
          ~s(" fill="none" stroke="),
          hex(a.color || {0.0, 0.0, 0.0}),
          ~s(" stroke-width="),
          n(a.width),
          ~s("/>)
        ]
      else
        []
      end

    [border, text_block(text, {x0 + 2, y0, x1 - 2, y1 - 2}, size, rgb, align, a.opacity)]
  end

  defp draw("Text", a) do
    {x0, _y0, _x1, y1} = a.rect
    fill = hex(a.color || {1.0, 0.82, 0.0})
    # an 18 pt speech bubble anchored at the top-left of the rectangle
    t = fn x, y -> [n(x0 + x), " ", n(y1 - y)] end

    [
      ~s(<g fill-opacity="),
      n(a.opacity),
      ~s(">),
      ~s(<path d="M),
      t.(1, 1),
      "L",
      t.(19, 1),
      "L",
      t.(19, 14),
      "L",
      t.(9, 14),
      "L",
      t.(5, 18),
      "L",
      t.(5, 14),
      "L",
      t.(1, 14),
      ~s(Z" fill="),
      fill,
      ~s(" stroke="#5c4a00" stroke-width="0.8" stroke-linejoin="round"/>),
      ~s(<path d="M),
      t.(4, 5),
      "L",
      t.(16, 5),
      "M",
      t.(4, 8),
      "L",
      t.(16, 8),
      "M",
      t.(4, 11),
      "L",
      t.(12, 11),
      ~s(" stroke="#5c4a00" stroke-width="0.8"/>),
      "</g>"
    ]
  end

  defp draw("Stamp", a) do
    {x0, y0, x1, y1} = a.rect
    name = a.get.("Name") || "Draft"

    label =
      name
      |> to_string()
      |> String.replace(~r/^#/, "")
      |> Macro.underscore()
      |> String.replace("_", " ")
      |> String.upcase()

    color = hex(a.color || {0.75, 0.1, 0.1})
    h = y1 - y0
    size = min(h * 0.6, (x1 - x0) / max(String.length(label), 1) * 1.6)

    [
      ~s(<g opacity="),
      n(a.opacity),
      ~s(">),
      ~s(<rect x="),
      n(x0 + 1.5),
      ~s(" y="),
      n(y0 + 1.5),
      ~s(" width="),
      n(max(x1 - x0 - 3, 0)),
      ~s(" height="),
      n(max(h - 3, 0)),
      ~s(" rx="),
      n(min(h / 6, 8)),
      ~s(" fill="none" stroke="),
      color,
      ~s(" stroke-width="3"/>),
      ~s(<text transform="matrix(1 0 0 -1 ),
      n((x0 + x1) / 2),
      " ",
      n(y0 + h / 2 - size * 0.35),
      ~s(\)" text-anchor="middle" font-family="Helvetica, Arial, sans-serif" font-weight="bold" font-size="),
      n(size),
      ~s(" fill="),
      color,
      ~s(">),
      escape(label),
      "</text>",
      "</g>"
    ]
  end

  defp draw("Caret", a) do
    {x0, y0, x1, y1} = a.rect

    [
      ~s(<path d="M),
      n(x0),
      " ",
      n(y0),
      "L",
      n((x0 + x1) / 2),
      " ",
      n(y1),
      "L",
      n(x1),
      " ",
      n(y0),
      ~s(" fill="none" stroke="),
      hex(a.color || {0.0, 0.0, 1.0}),
      ~s(" stroke-width="1"/>)
    ]
  end

  defp draw("FileAttachment", a) do
    {x0, _y0, _x1, y1} = a.rect
    color = hex(a.color || {0.2, 0.2, 0.2})
    t = fn x, y -> [n(x0 + x), " ", n(y1 - y)] end

    [
      ~s(<path d="M),
      t.(10, 4),
      "L",
      t.(10, 14),
      "C",
      t.(10, 18),
      t.(4, 18),
      t.(4, 14),
      "L",
      t.(4, 5),
      "C",
      t.(4, 1),
      t.(8, 1),
      t.(8, 5),
      "L",
      t.(8, 13),
      ~s(" fill="none" stroke="),
      color,
      ~s(" stroke-width="1.2" stroke-linecap="round"/>)
    ]
  end

  defp draw("Redact", a) do
    color = hex(a.color || {0.9, 0.1, 0.1})

    shapes =
      case quads(a) do
        [] ->
          []

        qs ->
          Enum.map(
            qs,
            &[
              ~s(<path d="),
              quad_d(&1),
              ~s(" fill="none" stroke="),
              color,
              ~s(" stroke-width="1"/>)
            ]
          )
      end

    shapes
  end

  defp draw("Widget", a) do
    doc = a.doc
    ft = inherited(a, "FT")
    {x0, y0, x1, y1} = a.rect

    case ft do
      "Tx" ->
        value = inherited(a, "V") |> to_text()
        {size, rgb} = default_appearance(inherited(a, "DA"))
        size = if size == 0, do: min(12.0, (y1 - y0) * 0.7), else: size
        align = inherited(a, "Q") || 0
        multiline? = Bitwise.band(inherited(a, "Ff") || 0, 4096) != 0

        if value == "" do
          nil
        else
          rect =
            if multiline?,
              do: {x0 + 2, y0, x1 - 2, y1 - 2},
              else: {x0 + 2, y0, x1 - 2, (y0 + y1) / 2 + size * 0.5}

          text_block(value, rect, size, rgb, align, 1.0)
        end

      "Btn" ->
        state = Document.resolve(doc, a.get.("AS")) || inherited(a, "V")

        if state not in [nil, "Off"] do
          size = min(x1 - x0, y1 - y0) * 0.8
          {_, rgb} = default_appearance(inherited(a, "DA"))

          [
            ~s(<text transform="matrix(1 0 0 -1 ),
            n((x0 + x1) / 2),
            " ",
            n((y0 + y1) / 2 - size * 0.35),
            ~s(\)" text-anchor="middle" font-size="),
            n(size),
            ~s(" fill="),
            hex(rgb),
            ~s(">&#x2713;</text>)
          ]
        end

      "Ch" ->
        {size, rgb} = default_appearance(inherited(a, "DA"))
        combo? = Bitwise.band(inherited(a, "Ff") || 0, 131_072) != 0

        if combo? do
          value =
            case inherited(a, "V") do
              [first | _] -> to_text(Document.resolve(doc, first))
              v -> to_text(v)
            end

          size = if size == 0, do: min(12.0, (y1 - y0) * 0.7), else: size

          if value != "",
            do:
              text_block(
                value,
                {x0 + 2, y0, x1 - 2, (y0 + y1) / 2 + size * 0.5},
                size,
                rgb,
                0,
                1.0
              )
        else
          list_box(a, a.rect, if(size == 0, do: 12.0, else: size), rgb)
        end

      _ ->
        nil
    end
  end

  defp draw(_subtype, _a), do: nil

  # ---------------------------------------------------------------- helpers

  # a list box: its options from the top index, selected ones highlighted the way PDFium does
  defp list_box(a, {x0, y0, x1, y1}, size, rgb) do
    doc = a.doc

    options =
      (inherited(a, "Opt") || [])
      |> Enum.map(&Document.resolve(doc, &1))
      |> Enum.map(fn
        [export, display | _] ->
          {to_text(Document.resolve(doc, export)), to_text(Document.resolve(doc, display))}

        v ->
          {to_text(v), to_text(v)}
      end)

    selected =
      case inherited(a, "I") do
        list when is_list(list) and list != [] ->
          list
          |> Enum.map(&Document.resolve(doc, &1))
          |> Enum.filter(&is_integer/1)
          |> MapSet.new()

        _ ->
          values =
            case inherited(a, "V") do
              list when is_list(list) -> Enum.map(list, &to_text(Document.resolve(doc, &1)))
              nil -> []
              v -> [to_text(v)]
            end

          options
          |> Enum.with_index()
          |> Enum.filter(fn {{export, display}, _} -> export in values or display in values end)
          |> Enum.map(&elem(&1, 1))
          |> MapSet.new()
      end

    top = inherited(a, "TI") || 0
    top = if is_integer(top), do: top, else: 0
    line_h = size * 1.15
    rows = max(trunc((y1 - y0 - 2) / line_h), 1)

    options
    |> Enum.with_index()
    |> Enum.drop(top)
    |> Enum.take(rows)
    |> Enum.with_index()
    |> Enum.map(fn {{{_export, display}, i}, row} ->
      top_y = y1 - 1 - row * line_h
      selected? = MapSet.member?(selected, i)

      bg =
        if selected?,
          do: [
            ~s(<rect x="),
            n(x0 + 1),
            ~s(" y="),
            n(top_y - line_h),
            ~s(" width="),
            n(max(x1 - x0 - 2, 0)),
            ~s(" height="),
            n(line_h),
            ~s(" fill="#003371"/>)
          ],
          else: []

      [
        bg,
        text_block(
          display,
          {x0 + 2, top_y - line_h, x1 - 2, top_y},
          size,
          if(selected?, do: {1.0, 1.0, 1.0}, else: rgb),
          0,
          1.0
        )
      ]
    end)
  end

  defp inherited(a, key) do
    find_inherited(a.doc, %{key => a.get.(key), "Parent" => a.get.("Parent")}, key, 0)
  end

  defp find_inherited(_doc, _node, _key, depth) when depth > 16, do: nil

  defp find_inherited(doc, node, key, depth) do
    case Document.resolve(doc, node[key]) do
      nil ->
        case Document.resolve(doc, node["Parent"]) do
          %{} = parent -> find_inherited(doc, parent, key, depth + 1)
          _ -> acroform_default(doc, key)
        end

      v ->
        v
    end
  end

  defp acroform_default(doc, key) when key in ["DA", "Q"] do
    Document.get(doc, Document.get(doc, Document.catalog(doc), "AcroForm"), key)
  end

  defp acroform_default(_doc, _key), do: nil

  defp to_text({:string, _} = s),
    do: s |> TextString.decode() |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

  defp to_text(name) when is_binary(name), do: name
  defp to_text(_), do: ""

  defp quads(a) do
    case nums(a.get.("QuadPoints")) do
      list when length(list) >= 8 ->
        list
        |> Enum.chunk_every(8, 8, :discard)
        |> Enum.map(fn [x1, y1, x2, y2, x3, y3, x4, y4] ->
          [{x1, y1}, {x2, y2}, {x3, y3}, {x4, y4}]
        end)

      _ ->
        case a.rect do
          {x0, y0, x1, y1} -> [[{x0, y1}, {x1, y1}, {x0, y0}, {x1, y0}]]
          nil -> []
        end
    end
  end

  defp quad_d([{x1, y1}, {x2, y2}, {x3, y3}, {x4, y4}]),
    do: [
      "M",
      n(x1),
      " ",
      n(y1),
      "L",
      n(x2),
      " ",
      n(y2),
      "L",
      n(x4),
      " ",
      n(y4),
      "L",
      n(x3),
      " ",
      n(y3),
      "Z"
    ]

  defp line({x1, y1}, {x2, y2}, color, lw, opacity) do
    [
      ~s(<path d="M),
      n(x1),
      " ",
      n(y1),
      "L",
      n(x2),
      " ",
      n(y2),
      ~s(" stroke="),
      color,
      ~s(" stroke-width="),
      n(lw),
      ~s(" stroke-opacity="),
      n(opacity),
      ~s("/>)
    ]
  end

  defp squiggle({x3, y3}, {x4, y4}, h, color, lw, opacity) do
    len = :math.sqrt((x4 - x3) * (x4 - x3) + (y4 - y3) * (y4 - y3))
    step = max(h / 6, 1.0)
    count = max(trunc(len / step), 1)
    {ux, uy} = if len > 0, do: {(x4 - x3) / len, (y4 - y3) / len}, else: {1.0, 0.0}
    {nx, ny} = {-uy, ux}
    amp = step / 2

    pts =
      for i <- 0..count do
        d = i * len / count
        o = if rem(i, 2) == 0, do: 0.0, else: amp
        [n(x3 + ux * d + nx * o), " ", n(y3 + uy * d + ny * o)]
      end

    [
      ~s(<path d="M),
      Enum.intersperse(pts, "L"),
      ~s(" fill="none" stroke="),
      color,
      ~s(" stroke-width="),
      n(lw),
      ~s(" stroke-opacity="),
      n(opacity),
      ~s("/>)
    ]
  end

  defp polyline_d(pts, closed?) do
    pairs = Enum.chunk_every(pts, 2, 2, :discard)

    [
      pairs
      |> Enum.with_index()
      |> Enum.map(fn {[x, y], i} -> [if(i == 0, do: "M", else: "L"), n(x), " ", n(y)] end),
      if(closed?, do: "Z", else: "")
    ]
  end

  defp shape_style(a) do
    fill = if a.interior, do: [~s( fill="), hex(a.interior), ~s(")], else: ~s( fill="none")

    [
      fill,
      if(a.color && a.width > 0, do: stroke_style(a), else: ""),
      if(a.opacity < 1, do: [~s( opacity="), n(a.opacity), ~s(")], else: "")
    ]
  end

  defp stroke_style(a) do
    [
      ~s( stroke="),
      hex(a.color || {0.0, 0.0, 0.0}),
      ~s(" stroke-width="),
      n(max(a.width, 0.5)),
      ~s("),
      if(a.dash != [],
        do: [~s( stroke-dasharray="), Enum.map_join(a.dash, " ", &n/1), ~s(")],
        else: ""
      ),
      if(a.opacity < 1, do: [~s( stroke-opacity="), n(a.opacity), ~s(")], else: "")
    ]
  end

  defp line_endings(a, p1, p2) do
    case a.get.("LE") do
      [s, e | _] -> [ending(a, s, p2, p1), ending(a, e, p1, p2)]
      _ -> []
    end
  end

  # an arrow at `tip`, pointing away from `from`
  defp ending(a, style, {fx, fy}, {tx, ty}) when style in ["OpenArrow", "ClosedArrow"] do
    len = :math.sqrt((tx - fx) * (tx - fx) + (ty - fy) * (ty - fy))

    if len == 0 do
      []
    else
      {ux, uy} = {(tx - fx) / len, (ty - fy) / len}
      size = max(a.width * 4, 6)
      {lx, ly} = {tx - ux * size - uy * size / 2, ty - uy * size + ux * size / 2}
      {rx, ry} = {tx - ux * size + uy * size / 2, ty - uy * size - ux * size / 2}
      color = hex(a.color || {0.0, 0.0, 0.0})
      closed? = style == "ClosedArrow"

      [
        ~s(<path d="M),
        n(lx),
        " ",
        n(ly),
        "L",
        n(tx),
        " ",
        n(ty),
        "L",
        n(rx),
        " ",
        n(ry),
        if(closed?, do: "Z", else: ""),
        ~s(" fill="),
        if(closed?, do: color, else: "none"),
        ~s(" stroke="),
        color,
        ~s(" stroke-width="),
        n(max(a.width, 0.5)),
        ~s("/>)
      ]
    end
  end

  defp ending(_a, _style, _from, _tip), do: []

  # text laid out top-down inside `rect` (user space, y up)
  defp text_block(text, {x0, y0, x1, y1}, size, rgb, align, opacity) do
    size = if size <= 0, do: 10.0, else: size / 1
    max_w = max(x1 - x0, 1)
    lines = text |> String.split("\n") |> Enum.flat_map(&wrap(&1, size, max_w))
    leading = size * 1.15

    {anchor, x} =
      case align do
        1 -> {"middle", (x0 + x1) / 2}
        2 -> {"end", x1}
        _ -> {"start", x0}
      end

    lines
    |> Enum.with_index()
    |> Enum.take_while(fn {_, i} -> y1 - (i + 1) * leading >= y0 - leading * 0.3 end)
    |> Enum.map(fn {line, i} ->
      y = y1 - size * 0.85 - i * leading

      [
        ~s(<text transform="matrix(1 0 0 -1 ),
        n(x),
        " ",
        n(y),
        ~s(\)" font-family="Helvetica, Arial, sans-serif" font-size="),
        n(size),
        ~s(" fill="),
        hex(rgb),
        ~s("),
        if(opacity < 1, do: [~s( fill-opacity="), n(opacity), ~s(")], else: ""),
        if(anchor != "start", do: [~s( text-anchor="), anchor, ~s(")], else: ""),
        ~s( xml:space="preserve">),
        escape(line),
        "</text>"
      ]
    end)
  end

  @helvetica AFM.get("Helvetica").widths

  defp text_width(text, size) do
    text
    |> String.codepoints()
    |> Enum.map(fn ch -> Map.get(@helvetica, GlyphList.to_name(ch) || "", 556) end)
    |> Enum.sum()
    |> Kernel.*(size / 1000)
  end

  defp wrap(line, size, max_w) do
    words = String.split(line, " ")

    {lines, current} =
      Enum.reduce(words, {[], nil}, fn word, {lines, current} ->
        candidate = if current, do: current <> " " <> word, else: word

        cond do
          current == nil -> {lines, word}
          text_width(candidate, size) <= max_w -> {lines, candidate}
          true -> {[current | lines], word}
        end
      end)

    Enum.reverse([current || "" | lines])
  end

  @doc false
  def default_appearance({:string, da}) do
    tokens = String.split(da)

    size =
      case Enum.find_index(tokens, &(&1 == "Tf")) do
        i when is_integer(i) and i >= 1 -> parse_num(Enum.at(tokens, i - 1))
        _ -> 0.0
      end

    rgb =
      cond do
        i = Enum.find_index(tokens, &(&1 == "rg")) -> rgb_at(tokens, i, 3)
        i = Enum.find_index(tokens, &(&1 == "g")) -> rgb_at(tokens, i, 1)
        i = Enum.find_index(tokens, &(&1 == "k")) -> rgb_at(tokens, i, 4)
        true -> {0.0, 0.0, 0.0}
      end

    {size, rgb}
  end

  def default_appearance(_), do: {0.0, {0.0, 0.0, 0.0}}

  defp rgb_at(tokens, i, count) when i >= count do
    comps = tokens |> Enum.slice(i - count, count) |> Enum.map(&parse_num/1)
    color(comps) || {0.0, 0.0, 0.0}
  end

  defp rgb_at(_, _, _), do: {0.0, 0.0, 0.0}

  defp parse_num(s) do
    case Float.parse(s) do
      {v, _} -> v
      :error -> 0.0
    end
  end

  defp color([g]) when is_number(g), do: ColorSpace.to_rgb(:gray, [g])
  defp color([r, g, b]) when is_number(r), do: ColorSpace.to_rgb(:rgb, [r, g, b])
  defp color([c, m, y, k]) when is_number(c), do: ColorSpace.to_rgb(:cmyk, [c, m, y, k])
  defp color(_), do: nil

  defp opacity(v) when is_number(v), do: v |> max(0) |> min(1) |> Kernel./(1)
  defp opacity(_), do: 1.0

  defp border_width(doc, annot) do
    case Document.get(doc, annot, "BS") do
      %{} = bs ->
        case Document.resolve(doc, bs["W"]) do
          w when is_number(w) -> w / 1
          _ -> 1.0
        end

      _ ->
        case Document.resolve(doc, annot["Border"]) do
          [_, _, w | _] when is_number(w) -> w / 1
          _ -> 1.0
        end
    end
  end

  defp border_dash(doc, annot) do
    case Document.get(doc, annot, "BS") do
      %{"S" => "D"} = bs -> nums(Document.resolve(doc, bs["D"]) || [3])
      _ -> []
    end
  end

  defp nums(list) when is_list(list), do: list |> Enum.filter(&is_number/1) |> Enum.map(&(&1 / 1))
  defp nums(_), do: []

  defp hex(rgb), do: ColorSpace.hex(rgb)

  defp n(x) when is_integer(x), do: Integer.to_string(x)

  defp n(x) do
    r = round(x * 1000)

    if rem(r, 1000) == 0,
      do: Integer.to_string(div(r, 1000)),
      else: :erlang.float_to_binary(r / 1000, [:compact, decimals: 3])
  end

  defp escape(text), do: EmbedPdf.Render.SVG.escape(text)
end
