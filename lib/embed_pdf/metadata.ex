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
          |> Enum.map(fn {k, v} -> {k, Document.resolve(doc, v) || %{}} end)
          |> Enum.sort_by(&elem(&1, 0))

        _ ->
          []
      end

    if ranges == [] do
      Enum.map(1..count//1, &Integer.to_string/1)
    else
      for i <- 0..(count - 1)//1 do
        case ranges |> Enum.filter(fn {start, _} -> start <= i end) |> List.last() do
          nil ->
            Integer.to_string(i + 1)

          {start, dict} ->
            first = Document.resolve(doc, dict["St"]) || 1
            n = i - start + first
            prefix = Edit.untext(Document.resolve(doc, dict["P"])) || ""
            prefix <> format(Document.resolve(doc, dict["S"]), n)
        end
      end
    end
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
      Enum.reduce(@roman, {"", n}, fn {v, s}, {acc, rest} ->
        {acc <> String.duplicate(s, div(rest, v)), rem(rest, v)}
      end)

    out
  end

  # A..Z, then AA..ZZ, AAA.. (the letter repeated)
  defp letters(n) when n <= 0, do: ""

  defp letters(n) do
    letter = <<?A + rem(n - 1, 26)>>
    String.duplicate(letter, div(n - 1, 26) + 1)
  end
end
