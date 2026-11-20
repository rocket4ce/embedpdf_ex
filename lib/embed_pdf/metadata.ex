defmodule EmbedPdf.Metadata do
  @moduledoc """
  Document information (title, author, subject, keywords, creator,
  producer, dates) and page labels.
  """

  alias EmbedPdf.Edit
  alias EmbedPdf.PDF.{Document, NameTree, TextString}

  @keys %{
    title: "Title",
    author: "Author",
    subject: "Subject",
    keywords: "Keywords",
    creator: "Creator",
    producer: "Producer"
  }

  @doc "Reads the document information dictionary."
  @spec get(Document.t()) :: map()
  def get(doc) do
    info = Document.info(doc)

    str = fn key ->
      case Document.resolve(doc, info[key]) do
        {:string, _} = s -> s |> TextString.decode() |> String.replace(<<0>>, "")
        _ -> nil
      end
    end

    %{
      title: str.("Title"),
      author: str.("Author"),
      subject: str.("Subject"),
      keywords: str.("Keywords"),
      creator: str.("Creator"),
      producer: str.("Producer"),
      created: TextString.parse_date(Document.resolve(doc, info["CreationDate"])),
      modified: TextString.parse_date(Document.resolve(doc, info["ModDate"])),
      custom:
        info
        |> Map.drop(Map.values(@keys) ++ ["CreationDate", "ModDate", "Trapped"])
        |> Enum.flat_map(fn {k, v} ->
          case Document.resolve(doc, v) do
            {:string, _} = s -> [{k, TextString.decode(s)}]
            _ -> []
          end
        end)
        |> Map.new()
    }
  end

  @doc """
  Updates the information dictionary. Keys: `:title`, `:author`,
  `:subject`, `:keywords`, `:creator`, `:producer`, `:created`, `:modified`
  (DateTime) and `:custom` (a map of extra string entries). A nil value
  removes the entry. The XMP metadata stream is dropped when it would
  contradict the new values.
  """
  @spec put(Document.t(), map() | keyword()) :: Document.t()
  def put(doc, changes) do
    changes = Map.new(changes)
    info = Document.info(doc)

    info =
      Enum.reduce(changes, info, fn
        {:created, dt}, acc ->
          put_entry(acc, "CreationDate", dt && Edit.date(dt))

        {:modified, dt}, acc ->
          put_entry(acc, "ModDate", dt && Edit.date(dt))

        {:custom, map}, acc ->
          Enum.reduce(map, acc, fn {k, v}, a -> put_entry(a, to_string(k), v && Edit.text(v)) end)

        {key, value}, acc when is_map_key(@keys, key) ->
          put_entry(acc, @keys[key], value && Edit.text(value))

        _, acc ->
          acc
      end)

    doc =
      case doc.trailer["Info"] do
        {:ref, _, _} = ref ->
          Document.put_object(doc, ref, info)

        _ ->
          {doc, ref} = Document.add_object(doc, info)
          %{doc | trailer: Map.put(doc.trailer, "Info", ref)}
      end

    if Enum.any?([:title, :author, :subject, :keywords], &Map.has_key?(changes, &1)),
      do: drop_xmp(doc),
      else: doc
  end

  defp put_entry(map, key, nil), do: Map.delete(map, key)
  defp put_entry(map, key, value), do: Map.put(map, key, value)

  defp drop_xmp(doc) do
    catalog = Document.catalog(doc)

    if Map.has_key?(catalog, "Metadata"),
      do: Document.put_object(doc, doc.trailer["Root"], Map.delete(catalog, "Metadata")),
      else: doc
  end

  # ---------------------------------------------------------------- page labels

  # What a label may grow to, whatever `/St` and `/P` say: Roman numerals
  # stop at 4999, letters repeat 64 times (page 1664 of a range), a prefix
  # keeps its first 256 bytes.
  @max_roman 4999
  @max_letters 64
  @max_prefix 256

  @doc "The label of every page (`/PageLabels`), or `\"1\"`, `\"2\"`, … without labels."
  @spec page_labels(Document.t()) :: [String.t()]
  def page_labels(doc) do
    count = Document.page_count(doc)

    ranges =
      case Document.get(doc, Document.catalog(doc), "PageLabels") do
        %{} = tree ->
          doc
          |> NameTree.number_entries(tree)
          |> Enum.filter(fn {k, _} -> is_integer(k) end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {k, v} -> {k, range(doc, Document.resolve(doc, v))} end)

        _ ->
          []
      end

    if ranges == [] do
      Enum.map(1..count//1, &Integer.to_string/1)
    else
      label_pages(0, count, nil, ranges, [])
    end
  end

  # the range of page i is the last one that starts at or before it: `ranges`
  # is sorted, so it is found by moving along with the pages
  defp label_pages(i, count, _current, _ranges, acc) when i >= count, do: Enum.reverse(acc)

  defp label_pages(i, count, _current, [{start, _} = range | ranges], acc) when start <= i,
    do: label_pages(i, count, range, ranges, acc)

  defp label_pages(i, count, nil, ranges, acc),
    do: label_pages(i + 1, count, nil, ranges, [Integer.to_string(i + 1) | acc])

  defp label_pages(i, count, {start, {style, first, prefix}} = current, ranges, acc) do
    label = prefix <> format(style, i - start + first)
    label_pages(i + 1, count, current, ranges, [label | acc])
  end

  # `{style, first number, prefix}` of a label dictionary
  defp range(doc, dict) when is_map(dict) and not is_struct(dict) do
    first =
      case Document.resolve(doc, dict["St"]) do
        n when is_integer(n) -> n
        _ -> 1
      end

    prefix = Edit.untext(Document.resolve(doc, dict["P"])) || ""
    {Document.resolve(doc, dict["S"]), first, clip(prefix)}
  end

  defp range(_doc, _), do: {nil, 1, ""}

  defp clip(prefix) when byte_size(prefix) <= @max_prefix, do: prefix

  defp clip(prefix) do
    cut = binary_part(prefix, 0, @max_prefix)
    if String.valid?(prefix), do: whole_characters(cut, 3), else: cut
  end

  # a cut in the middle of a character leaves up to three bytes of it
  defp whole_characters(text, 0), do: text

  defp whole_characters(text, n) do
    if String.valid?(text),
      do: text,
      else: whole_characters(binary_part(text, 0, byte_size(text) - 1), n - 1)
  end

  defp format("D", n), do: Integer.to_string(n)
  defp format("R", n), do: roman(n)
  defp format("r", n), do: n |> roman() |> String.downcase()
  defp format("A", n), do: letters(n)
  defp format("a", n), do: n |> letters() |> String.downcase()
  defp format(_, _), do: ""

  @roman [
    {1000, "M"},
    {900, "CM"},
    {500, "D"},
    {400, "CD"},
    {100, "C"},
    {90, "XC"},
    {50, "L"},
    {40, "XL"},
    {10, "X"},
    {9, "IX"},
    {5, "V"},
    {4, "IV"},
    {1, "I"}
  ]

  defp roman(n) when n <= 0, do: ""

  defp roman(n) do
    {out, _} =
      Enum.reduce(@roman, {"", min(n, @max_roman)}, fn {v, s}, {acc, rest} ->
        {acc <> String.duplicate(s, div(rest, v)), rem(rest, v)}
      end)

    out
  end

  # A..Z, then AA..ZZ, AAA.. (the letter repeated)
  defp letters(n) when n <= 0, do: ""

  defp letters(n) do
    letter = <<?A + rem(n - 1, 26)>>
    String.duplicate(letter, min(div(n - 1, 26) + 1, @max_letters))
  end
end
