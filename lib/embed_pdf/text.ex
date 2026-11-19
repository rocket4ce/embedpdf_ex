defmodule EmbedPdf.Text do
  @moduledoc """
  Text extraction with geometry.

  A page's text is read in content order, glyph by glyph, then joined into
  lines; spaces and line breaks the PDF does not spell out are inserted
  from the gaps between glyphs. Every character of the resulting string
  keeps its box, so search hits and selections map back to rectangles.

  Boxes are `{x0, y0, x1, y1}` in page points with the origin at the
  top-left of the page as displayed (the page's own `/Rotate` applied).
  """

  alias EmbedPdf.PDF.{Document, Page}
  alias EmbedPdf.Render.{Interpreter, Matrix}

  defmodule Char do
    @moduledoc false
    defstruct [:text, :box, :size, :angle, :font, synthetic?: false]
  end

  defmodule Line do
    @moduledoc false
    defstruct [:text, :box, :size, :angle, :start, :length, :font]
  end

  defmodule PageText do
    @moduledoc """
    `text` is the page's text; `chars` is a tuple with one `%Char{}` per
    grapheme of `text` (line breaks included); `lines` describe each line.
    """
    defstruct text: "", chars: {}, lines: [], index: 0
  end

  @doc "Extracts the text of page `index` (zero-based)."
  @spec page(Document.t(), non_neg_integer()) :: PageText.t()
  def page(doc, index) do
    case Document.page(doc, index) do
      nil -> %PageText{index: index}
      page -> extract(doc, page)
    end
  end

  @doc "Extracts the text of a page."
  @spec extract(Document.t(), Page.t()) :: PageText.t()
  def extract(doc, %Page{} = page) do
    view = Page.view_matrix(page)

    glyphs =
      doc
      |> Interpreter.run_page(page, &collect/2, [], text_only: true)
      |> Enum.reverse()
      |> Enum.flat_map(&to_glyph(&1, view))

    {chars, lines} = layout(glyphs)
    chars = chars |> Enum.reverse()
    text = Enum.map_join(chars, & &1.text)
    %PageText{text: text, chars: List.to_tuple(chars), lines: lines, index: page.index}
  end

  defp collect({:glyph, %{gs: %{render_mode: _}} = g}, acc), do: [g | acc]
  defp collect(_, acc), do: acc

  defp to_glyph(%{font: font, glyph: {_code, _cid, uni, w0, _n}, trm: trm}, view) do
    [a, b, c, d, e, f] = trm
    xlen = :math.sqrt(a * a + b * b)
    size = :math.sqrt(c * c + d * d)

    if uni == "" or size < 0.01 do
      []
    else
      w = if w0 <= 0, do: 0.5, else: w0
      asc = max(font.ascent, 0.5) |> min(1.2)
      desc = min(font.descent, -0.05) |> max(-0.5)
      device = Matrix.multiply(trm, view)
      box = Matrix.transform_rect(device, {0.0, desc, w, asc})
      [da, db | _] = device

      [
        %{
          text: uni,
          box: box,
          origin: {e, f},
          dir: {a / max(xlen, 1.0e-9), b / max(xlen, 1.0e-9)},
          advance: w * xlen,
          size: size,
          angle: :math.atan2(db, da) * 180 / :math.pi(),
          font: font.id
        }
      ]
    end
  end

  # ---------------------------------------------------------------- layout

  defp layout([]), do: {[], []}

  defp layout(glyphs) do
    {chars, lines, current, _prev} =
      Enum.reduce(glyphs, {[], [], nil, nil}, fn g, {chars, lines, current, prev} ->
        case relation(prev, g) do
          :first ->
            {push_glyph(chars, g), lines, start_line(g, 0), g}

          :same ->
            {push_glyph(chars, g), lines, extend_line(current, g), g}

          :space ->
            space = synthetic(" ", prev, g)
            chars = [space | chars]
            {push_glyph(chars, g), lines, current |> extend_line(space) |> extend_line(g), g}

          :newline ->
            {chars, lines} = close_line(chars, lines, current, prev)
            start = count(chars)
            {push_glyph(chars, g), lines, start_line(g, start), g}
        end
      end)

    {chars, lines} = close_line(chars, lines, current, nil, false)
    {chars, Enum.reverse(lines)}
  end

  defp count(chars), do: length(chars)

  defp push_glyph(chars, g) do
    # ligatures and multi-character mappings: split the box among graphemes
    graphemes = String.graphemes(g.text)
    n = length(graphemes)

    if n <= 1 do
      [%Char{text: g.text, box: g.box, size: g.size, angle: g.angle, font: g.font} | chars]
    else
      {x0, y0, x1, y1} = g.box
      horizontal? = x1 - x0 >= (y1 - y0) * 0.3
      step = if horizontal?, do: (x1 - x0) / n, else: (y1 - y0) / n

      graphemes
      |> Enum.with_index()
      |> Enum.reduce(chars, fn {t, i}, acc ->
        box =
          if horizontal?,
            do: {x0 + i * step, y0, x0 + (i + 1) * step, y1},
            else: {x0, y0 + i * step, x1, y0 + (i + 1) * step}

        [%Char{text: t, box: box, size: g.size, angle: g.angle, font: g.font} | acc]
      end)
    end
  end

  defp synthetic(text, prev, g) do
    {_, py0, px1, py1} = prev.box
    {gx0, gy0, _, gy1} = g.box
    box = {min(px1, gx0), min(py0, gy0), max(px1, gx0), max(py1, gy1)}

    %Char{
      text: text,
      box: box,
      size: prev.size,
      angle: prev.angle,
      font: prev.font,
      synthetic?: true
    }
  end

  defp start_line(g, start),
    do: %{
      start: start,
      box: g.box,
      size: g.size,
      angle: g.angle,
      font: g.font,
      count: length(String.graphemes(g.text)),
      text: [g.text]
    }

  defp extend_line(line, %Char{text: t, box: box}),
    do: %{line | box: union(line.box, box), count: line.count + 1, text: [line.text | t]}

  defp extend_line(line, g),
    do: %{
      line
      | box: union(line.box, g.box),
        count: line.count + length(String.graphemes(g.text)),
        text: [line.text, g.text],
        size: max(line.size, g.size)
    }

  defp close_line(chars, lines, line, prev, newline? \\ true)
  defp close_line(chars, lines, nil, _prev, _), do: {chars, lines}

  defp close_line(chars, lines, line, prev, newline?) do
    record = %Line{
      text: IO.iodata_to_binary(line.text),
      box: line.box,
      size: line.size,
      angle: line.angle,
      start: line.start,
      length: line.count,
      font: line.font
    }

    chars =
      if newline? and prev do
        {_x0, y0, x1, y1} = prev.box

        [
          %Char{
            text: "\n",
            box: {x1, y0, x1, y1},
            size: prev.size,
            angle: prev.angle,
            font: prev.font,
            synthetic?: true
          }
          | chars
        ]
      else
        chars
      end

    {chars, [record | lines]}
  end

  defp relation(nil, _g), do: :first

  defp relation(prev, g) do
    {dx, dy} = prev.dir
    {gx, gy} = g.dir
    {px, py} = prev.origin
    {ox, oy} = g.origin
    size = max(prev.size, g.size)

    same_dir? = dx * gx + dy * gy > 0.95
    # offset of g's origin relative to where prev ended, in prev's frame
    ex = px + dx * prev.advance
    ey = py + dy * prev.advance
    along = (ox - ex) * dx + (oy - ey) * dy
    across = -(ox - px) * dy + (oy - py) * dx

    cond do
      not same_dir? -> :newline
      abs(across) > size * 0.6 -> :newline
      along < -size * 1.2 and along < -(prev.advance + size) -> :newline
      along > size * 0.18 and not space?(prev.text) and not space?(g.text) -> :space
      true -> :same
    end
  end

  defp space?(t), do: String.trim(t) == ""

  defp union({a0, b0, a1, b1}, {c0, d0, c1, d1}),
    do: {min(a0, c0), min(b0, d0), max(a1, c1), max(b1, d1)}

  # ---------------------------------------------------------------- queries

  @doc "Plain text of a page."
  @spec text(PageText.t()) :: String.t()
  def text(%PageText{text: t}), do: t

  @doc """
  Rectangles covering characters `from..to` (inclusive indices into the
  page's graphemes), merged per line.
  """
  @spec rects(PageText.t(), non_neg_integer(), non_neg_integer()) :: [
          {float(), float(), float(), float()}
        ]
  def rects(%PageText{chars: chars}, from, to) do
    last = tuple_size(chars) - 1
    from = max(from, 0)
    to = min(to, last)

    if from > to do
      []
    else
      from..to
      |> Enum.map(&elem(chars, &1))
      |> Enum.reject(&(&1.text == "\n"))
      |> Enum.chunk_while(
        nil,
        fn c, acc ->
          cond do
            acc == nil -> {:cont, {c.box, c.size}}
            same_row?(elem(acc, 0), c.box) -> {:cont, {union(elem(acc, 0), c.box), elem(acc, 1)}}
            true -> {:cont, elem(acc, 0), {c.box, c.size}}
          end
        end,
        fn
          nil -> {:cont, nil}
          acc -> {:cont, elem(acc, 0), nil}
        end
      )
      |> Enum.reject(&is_nil/1)
    end
  end

  defp same_row?({_, a0, _, a1}, {_, b0, _, b1}) do
    overlap = min(a1, b1) - max(a0, b0)
    overlap > 0.5 * min(a1 - a0, b1 - b0)
  end

  @doc "Text of characters `from..to`."
  @spec slice(PageText.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def slice(%PageText{chars: chars}, from, to) do
    last = tuple_size(chars) - 1
    from = max(from, 0)
    to = min(to, last)
    if from > to, do: "", else: Enum.map_join(from..to, &elem(chars, &1).text)
  end

  @doc """
  Index of the character nearest to the point `{x, y}` (page points,
  top-left origin), or nil on an empty page.
  """
  @spec char_at(PageText.t(), {number(), number()}) :: non_neg_integer() | nil
  def char_at(%PageText{chars: {}}, _), do: nil

  def char_at(%PageText{chars: chars}, {x, y}) do
    chars
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reject(fn {c, _} -> c.text == "\n" end)
    |> Enum.min_by(
      fn {%Char{box: {x0, y0, x1, y1}}, _} ->
        dx =
          cond do
            x < x0 -> x0 - x
            x > x1 -> x - x1
            true -> 0
          end

        dy =
          cond do
            y < y0 -> y0 - y
            y > y1 -> y - y1
            true -> 0
          end

        # vertical distance dominates so a click picks its line first
        dy * 4 + dx
      end,
      fn -> nil end
    )
    |> case do
      nil -> nil
      {_, i} -> i
    end
  end

  @doc "The word (run of letters/digits) around character `i`, as `{from, to}`."
  @spec word_at(PageText.t(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def word_at(%PageText{chars: chars}, i) do
    word? = fn j ->
      j >= 0 and j < tuple_size(chars) and
        String.match?(elem(chars, j).text, ~r/^[\p{L}\p{N}_'’-]$/u)
    end

    if word?.(i) do
      from = Enum.find(i..0//-1, 0, fn j -> not word?.(j - 1) end)
      to = Enum.find(i..(tuple_size(chars) - 1)//1, i, fn j -> not word?.(j + 1) end)
      {from, to}
    else
      {i, i}
    end
  end

  @doc "The line around character `i`, as `{from, to}`."
  def line_at(%PageText{lines: lines}, i) do
    case Enum.find(lines, fn l -> i >= l.start and i < l.start + l.length end) do
      nil -> {i, i}
      l -> {l.start, l.start + l.length - 1}
    end
  end

  @doc """
  Finds `query` in a page. Options: `:case_sensitive` (false),
  `:whole_word` (false). Returns `[%{from:, to:, rects:, text:, context:}]`.
  """
  @spec search(PageText.t(), String.t(), keyword()) :: [map()]
  def search(%PageText{} = pt, query, opts \\ []) do
    query = String.trim(query)

    if query == "" do
      []
    else
      case_sensitive = Keyword.get(opts, :case_sensitive, false)
      whole = Keyword.get(opts, :whole_word, false)

      graphemes = pt.chars |> Tuple.to_list() |> Enum.map(&normalize_char(&1.text))
      haystack = Enum.join(graphemes)
      offsets = grapheme_offsets(graphemes)
      pattern = query |> normalize_space() |> Regex.escape() |> String.replace("\\ ", "\\s+")

      pattern =
        if whole, do: "(?<![\\p{L}\\p{N}])" <> pattern <> "(?![\\p{L}\\p{N}])", else: pattern

      pattern
      |> Regex.compile!(if(case_sensitive, do: "u", else: "iu"))
      |> Regex.scan(haystack, return: :index)
      |> Enum.map(fn [{start, len}] ->
        from = Map.fetch!(offsets, start)
        to = Map.get(offsets, start + len, tuple_size(pt.chars)) - 1
        context_from = max(from - 40, 0)
        context_to = min(to + 40, tuple_size(pt.chars) - 1)

        %{
          page: pt.index,
          from: from,
          to: to,
          rects: rects(pt, from, to),
          text: slice(pt, from, to),
          before: pt |> slice(context_from, from - 1) |> normalize_space(),
          after: pt |> slice(to + 1, context_to) |> normalize_space()
        }
      end)
    end
  end

  defp normalize_char("\n"), do: " "
  defp normalize_char(" "), do: " "
  defp normalize_char(t), do: t

  defp normalize_space(s), do: String.replace(s, ~r/\s+/u, " ")

  defp grapheme_offsets(graphemes) do
    {map, total, idx} =
      Enum.reduce(graphemes, {%{}, 0, 0}, fn g, {m, off, i} ->
        {Map.put(m, off, i), off + byte_size(g), i + 1}
      end)

    Map.put(map, total, idx)
  end
end
