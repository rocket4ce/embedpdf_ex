defmodule EmbedPdf.Edit do
  @moduledoc """
  Helpers shared by the editing modules: PDF values from Elixir terms,
  content stream building, page dictionary updates and standard-font text
  layout (Helvetica, Times and Courier in WinAnsiEncoding).
  """

  alias EmbedPdf.Font.{AFM, Encoding, GlyphList}
  alias EmbedPdf.PDF.{Document, Page, Serializer, Stream, TextString}

  # ---------------------------------------------------------------- values

  @doc "A PDF text string value."
  @spec text(String.t() | nil) :: {:string, binary()} | nil
  def text(nil), do: nil
  def text(s) when is_binary(s), do: {:string, TextString.encode(s)}

  @doc "Decodes a PDF text string value (nil for anything else)."
  @spec untext(term()) :: String.t() | nil
  def untext({:string, _} = s), do: TextString.decode(s)
  def untext(_), do: nil

  @doc "A PDF date string for `dt` (now when nil)."
  def date(dt \\ nil),
    do: {:string, TextString.format_date(dt || DateTime.utc_now() |> DateTime.truncate(:second))}

  @doc "A `{r, g, b}` color as a PDF array (nil passes through)."
  def color(nil), do: nil
  def color({r, g, b}), do: [num(r), num(g), num(b)]

  @doc "Reads a PDF color array into `{r, g, b}`."
  @spec uncolor(term()) :: {float(), float(), float()} | nil
  def uncolor([g]) when is_number(g), do: {g / 1, g / 1, g / 1}

  def uncolor([r, g, b]) when is_number(r) and is_number(g) and is_number(b),
    do: {r / 1, g / 1, b / 1}

  def uncolor([c, m, y, k]) when is_number(c) and is_number(m) and is_number(y) and is_number(k),
    do: {(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)}

  def uncolor(_), do: nil

  @doc "Rounds a number for writing (keeps integers)."
  def num(n) when is_integer(n), do: n
  def num(n) when is_float(n), do: Float.round(n, 4)

  @doc "A rectangle tuple as a PDF array."
  def rect_array({x0, y0, x1, y1}), do: [num(x0), num(y0), num(x1), num(y1)]

  @doc "Formats a number for a content stream."
  def f(n), do: Serializer.format_real(n)

  @doc "Normalizes `{x0, y0, x1, y1}` so x0 <= x1 and y0 <= y1."
  def normalize({a, b, c, d}), do: {min(a, c) / 1, min(b, d) / 1, max(a, c) / 1, max(b, d) / 1}

  @doc "Bounding box of points, grown by `pad`."
  def bbox(points, pad \\ 0) do
    {xs, ys} = Enum.unzip(points)
    {Enum.min(xs) - pad, Enum.min(ys) - pad, Enum.max(xs) + pad, Enum.max(ys) + pad}
  end

  @doc "Union of rectangles."
  def union([]), do: nil

  def union(rects),
    do:
      Enum.reduce(rects, fn {a, b, c, d}, {e, g, h, i} ->
        {min(a, e), min(b, g), max(c, h), max(d, i)}
      end)

  @doc "Whether two rectangles overlap (with positive area)."
  def overlap?({a0, b0, a1, b1}, {c0, d0, c1, d1}),
    do: min(a1, c1) > max(a0, c0) and min(b1, d1) > max(b0, d0)

  @doc "Area of the intersection of two rectangles."
  def overlap_area({a0, b0, a1, b1}, {c0, d0, c1, d1}) do
    w = min(a1, c1) - max(a0, c0)
    h = min(b1, d1) - max(b0, d0)
    if w > 0 and h > 0, do: w * h, else: 0.0
  end

  @doc "Whether `inner` lies within `outer` (with a small tolerance)."
  def inside?({a0, b0, a1, b1}, {c0, d0, c1, d1}, tol \\ 0.01),
    do: a0 >= c0 - tol and b0 >= d0 - tol and a1 <= c1 + tol and b1 <= d1 + tol

  @doc "A random annotation name (`/NM`)."
  def unique_name do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    hex = fn v, n ->
      v |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(n, "0")
    end

    "#{hex.(a, 8)}-#{hex.(b, 4)}-4#{hex.(c, 4) |> String.slice(1, 3)}-#{hex.(d, 4)}-#{hex.(e, 12)}"
  end

  @doc "A form XObject stream."
  def form(bbox, content, resources \\ %{}, extra \\ %{}) do
    %Stream{
      dict:
        Map.merge(
          %{
            "Type" => "XObject",
            "Subtype" => "Form",
            "FormType" => 1,
            "BBox" => rect_array(bbox),
            "Resources" => resources
          },
          extra
        ),
      raw: IO.iodata_to_binary(content)
    }
  end

  # ---------------------------------------------------------------- pages

  @doc "Replaces the dictionary of page `index` (via `fun`) and refreshes the page list."
  @spec update_page(Document.t(), non_neg_integer(), (map() -> map())) :: Document.t()
  def update_page(doc, index, fun) do
    case Document.page(doc, index) do
      %Page{ref: {:ref, _, _} = ref} ->
        dict = Document.resolve(doc, ref)
        doc |> Document.put_object(ref, fun.(dict)) |> Document.refresh_pages()

      _ ->
        doc
    end
  end

  @doc "The page's `/Annots` as a list of values (references or dicts)."
  def annots(doc, %Page{ref: ref}) do
    case Document.resolve(doc, ref) do
      %{} = dict -> List.wrap(Document.resolve(doc, dict["Annots"]))
      _ -> []
    end
  end

  @doc "Sets the page's `/Annots` (writing through an indirect array when there is one)."
  def put_annots(doc, %Page{ref: ref} = page, list) do
    dict = Document.resolve(doc, ref)

    case dict["Annots"] do
      {:ref, _, _} = aref -> Document.put_object(doc, aref, list)
      _ -> update_page(doc, page.index, &Map.put(&1, "Annots", list))
    end
    |> Document.refresh_pages()
  end

  @doc """
  Appends drawing to a page: existing content is wrapped in `q`/`Q`, then
  `content` runs with `resources` merged into a private copy of the page's
  resources (so pages sharing resources are not affected).
  """
  @spec append_content(Document.t(), non_neg_integer(), iodata(), map()) :: Document.t()
  def append_content(doc, index, content, resources \\ %{}) do
    page = Document.page(doc, index)
    {doc, pre} = Document.add_object(doc, %Stream{dict: %{}, raw: "q\n"})

    {doc, post} =
      Document.add_object(doc, %Stream{
        dict: %{},
        raw: IO.iodata_to_binary(["\nQ\n", content, "\n"])
      })

    existing =
      case Document.resolve(doc, page.dict["Contents"]) do
        list when is_list(list) -> list
        nil -> []
        _ -> [page.dict["Contents"]]
      end

    merged = merge_resources(doc, page.resources, resources)

    update_page(doc, index, fn dict ->
      dict
      |> Map.put("Contents", [pre | existing] ++ [post])
      |> Map.put("Resources", merged)
    end)
  end

  @doc "Merges resource categories (`Font`, `XObject`, ...) into a copy of `base`."
  def merge_resources(doc, base, extra) do
    base = Document.resolve(doc, base) || %{}

    Enum.reduce(extra, base, fn {cat, entries}, acc ->
      existing = Document.resolve(doc, acc[cat])
      existing = if is_map(existing), do: existing, else: %{}
      Map.put(acc, cat, Map.merge(existing, entries))
    end)
  end

  @doc "A resource name not used yet in `category` of `resources`."
  def fresh_name(doc, resources, category, prefix) do
    taken = Document.get(doc, resources || %{}, category) || %{}
    taken = if is_map(taken), do: taken, else: %{}
    first_free(taken, prefix, 1)
  end

  defp first_free(taken, prefix, i) do
    name = prefix <> Integer.to_string(i)
    if Map.has_key?(taken, name), do: first_free(taken, prefix, i + 1), else: name
  end

  @doc "Drops objects no longer reachable from the trailer (keeps documents small after big edits)."
  def collect_garbage(doc) do
    keep = Serializer.reachable(doc, Map.take(doc.trailer, ["Root", "Info"]))
    %{doc | objects: Map.filter(doc.objects, fn {n, _} -> MapSet.member?(keep, n) end)}
  end

  # ---------------------------------------------------------------- standard-font text

  @winansi Encoding.named("WinAnsiEncoding")
  @uni_to_win @winansi
              |> Enum.flat_map(fn {code, name} ->
                case GlyphList.to_unicode(name) do
                  nil -> []
                  u -> [{u, code}]
                end
              end)
              |> Enum.sort_by(fn {_, code} -> code end, :desc)
              |> Map.new()
              |> Map.merge(%{" " => 32, "-" => 45, " " => 32})

  @fonts %{
    helvetica: {"Helv", "Helvetica", "Helvetica-Bold"},
    times: {"TiRo", "Times-Roman", "Times-Bold"},
    courier: {"Cour", "Courier", "Courier-Bold"}
  }

  @doc "Encodes text as WinAnsiEncoding bytes (unmappable characters become `?`)."
  @spec winansi(String.t()) :: binary()
  def winansi(text) do
    for g <- String.graphemes(text), into: <<>> do
      case Map.fetch(@uni_to_win, g) do
        {:ok, code} -> <<code>>
        :error -> if g =~ ~r/^\s$/u, do: " ", else: "?"
      end
    end
  end

  @doc "Resource name and base font of a standard family."
  def std_font(family, bold? \\ false) do
    {res, regular, bold} = Map.get(@fonts, family, @fonts.helvetica)
    if bold?, do: {res <> "B", bold}, else: {res, regular}
  end

  @doc "A simple standard font dictionary (WinAnsiEncoding)."
  def std_font_dict(base),
    do: %{
      "Type" => "Font",
      "Subtype" => "Type1",
      "BaseFont" => base,
      "Encoding" => "WinAnsiEncoding"
    }

  @doc "Width in points of text set in a standard font."
  @spec text_width(String.t(), String.t(), number()) :: float()
  def text_width(text, base, size) do
    widths = (AFM.get(base) || AFM.get("Helvetica")).widths

    total =
      for <<code <- winansi(text)>>, reduce: 0 do
        acc -> acc + Map.get(widths, Map.get(@winansi, code, "space"), 500)
      end

    total * size / 1000
  end

  @doc "Wraps text into lines that fit `max_width` (explicit newlines are kept)."
  @spec wrap(String.t(), String.t(), number(), number()) :: [String.t()]
  def wrap(text, base, size, max_width) do
    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.flat_map(&wrap_para(&1, base, size, max_width))
  end

  defp wrap_para(para, base, size, max_width) do
    words =
      para
      |> String.split(" ")
      |> Enum.flat_map(fn w ->
        if String.length(w) > 1 and text_width(w, base, size) > max_width,
          do: w |> split_word(base, size, max_width) |> Enum.reverse(),
          else: [w]
      end)

    {lines, current} =
      Enum.reduce(words, {[], nil}, fn w, {lines, current} ->
        cond do
          current == nil -> {lines, w}
          text_width(current <> " " <> w, base, size) <= max_width -> {lines, current <> " " <> w}
          true -> {[current | lines], w}
        end
      end)

    Enum.reverse([current || "" | lines])
  end

  defp split_word(word, base, size, max_width) do
    word
    |> String.graphemes()
    |> Enum.reduce([""], fn g, [cur | rest] ->
      if cur == "" or text_width(cur <> g, base, size) <= max_width,
        do: [cur <> g | rest],
        else: [g, cur | rest]
    end)
  end

  @doc "A text-showing content fragment: `(bytes) Tj` with proper escaping."
  def tj(text), do: [Serializer.serialize({:string, winansi(text)}), " Tj"]
end
