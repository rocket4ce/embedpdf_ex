defmodule EmbedPdf.PDF.Incremental do
  @moduledoc """
  Incremental updates (ISO 32000-1, 7.5.6): changed and new objects are
  appended after the original bytes with a new cross-reference section
  whose trailer points back with `/Prev`. The original bytes are never
  touched, so earlier digital signatures stay valid.

  The new section is a classic table, or a cross-reference stream when
  the file's newest section is one.
  """

  alias EmbedPdf.PDF.{Document, Parser, Serializer, Stream, Xref}

  @typedoc """
  Object values to write, by object number. A value can be any object, or
  `{:raw, iodata}` to write the object's body verbatim (used for signature
  dictionaries whose placeholders are filled in afterwards).
  """
  @type changes :: %{pos_integer() => term()}

  @doc """
  Appends `changes` to `original` with `trailer_updates` merged into the
  new trailer. Returns the new file bytes, or `{:error, :encrypted}` for
  encrypted files (objects would have to be encrypted too) and
  `{:error, :no_xref}` when the original has no usable cross-reference.
  """
  @spec append(binary(), changes(), map()) :: binary() | {:error, atom()}
  def append(original, changes, trailer_updates \\ %{}) do
    with {:ok, start} <- startxref(original),
         {entries, trailer, false} <- Xref.load(original),
         nil <- trailer["Encrypt"] do
      write(original, start, entries, trailer, changes, trailer_updates)
    else
      {_entries, _trailer, true} -> {:error, :no_xref}
      {:ref, _, _} -> {:error, :encrypted}
      %{} -> {:error, :encrypted}
      :error -> {:error, :no_xref}
      _ -> {:error, :encrypted}
    end
  end

  @doc """
  Appends the objects that differ between `before` and `after` (two
  documents opened from, or derived from, `original`). Object numbers
  are the document's own, so they match the original file.
  """
  @spec append_diff(binary(), Document.t(), Document.t(), changes(), map()) ::
          binary() | {:error, atom()}
  def append_diff(original, before, after_doc, extra \\ %{}, trailer_updates \\ %{}) do
    append(original, Map.merge(diff(before, after_doc), extra), trailer_updates)
  end

  @doc "Objects of `after_doc` that are new or changed compared with `before`."
  @spec diff(Document.t(), Document.t()) :: changes()
  def diff(before, after_doc) do
    for {num, value} <- after_doc.objects,
        Map.get(before.objects, num) != value,
        into: %{},
        do: {num, value}
  end

  defp write(original, prev, entries, old_trailer, changes, updates) do
    original = if String.ends_with?(original, "\n"), do: original, else: original <> "\n"
    gens = for {num, {:offset, _, gen}} <- entries, into: %{}, do: {num, gen}
    nums = changes |> Map.keys() |> Enum.sort()

    {chunks, offsets, pos} =
      Enum.reduce(nums, {[], %{}, byte_size(original)}, fn num, {chunks, offsets, pos} ->
        gen = Map.get(gens, num, 0)
        body = body(Map.fetch!(changes, num))

        chunk =
          IO.iodata_to_binary([
            Integer.to_string(num),
            " ",
            Integer.to_string(gen),
            " obj\n",
            body,
            "\nendobj\n"
          ])

        {[chunk | chunks], Map.put(offsets, num, {pos, gen}), pos + byte_size(chunk)}
      end)

    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    old_size = old_trailer["Size"] || 0
    max_num = Enum.max([old_size - 1 | nums], fn -> 0 end)

    trailer =
      old_trailer
      |> Map.take(["Root", "Info", "ID"])
      |> Map.merge(updates)
      |> Map.put("Prev", prev)

    xref_stream? = xref_stream?(original, prev)

    tail =
      if xref_stream? do
        stream_section(pos, offsets, max_num + 2, trailer)
      else
        table_section(pos, offsets, max(old_size, max_num + 1), trailer)
      end

    IO.iodata_to_binary([original, body, tail])
  end

  defp body({:raw, iodata}), do: iodata
  defp body(value), do: Serializer.serialize(value)

  defp table_section(pos, offsets, size, trailer) do
    sections =
      offsets
      |> Enum.sort()
      |> Enum.chunk_while(
        [],
        fn {num, _} = e, acc ->
          case acc do
            [{prev, _} | _] when num == prev + 1 -> {:cont, [e | acc]}
            [] -> {:cont, [e]}
            _ -> {:cont, Enum.reverse(acc), [e]}
          end
        end,
        fn
          [] -> {:cont, []}
          acc -> {:cont, Enum.reverse(acc), []}
        end
      )

    table = [
      "xref\n",
      Enum.map(sections, fn [{first, _} | _] = run ->
        [
          Integer.to_string(first),
          " ",
          Integer.to_string(length(run)),
          "\n",
          Enum.map(run, fn {_, {off, gen}} ->
            [pad(off, 10), " ", pad(gen, 5), " n \n"]
          end)
        ]
      end)
    ]

    [
      table,
      "trailer\n",
      Serializer.serialize(Map.put(trailer, "Size", size)),
      "\nstartxref\n",
      Integer.to_string(pos),
      "\n%%EOF\n"
    ]
  end

  # a cross-reference stream: its own object takes the next free number
  defp stream_section(pos, offsets, size, trailer) do
    num = size - 1
    offsets = Map.put(offsets, num, {pos, 0})
    sorted = Enum.sort(offsets)

    index =
      sorted
      |> Enum.chunk_while(
        [],
        fn {n, _} = e, acc ->
          case acc do
            [{prev, _} | _] when n == prev + 1 -> {:cont, [e | acc]}
            [] -> {:cont, [e]}
            _ -> {:cont, Enum.reverse(acc), [e]}
          end
        end,
        fn
          [] -> {:cont, []}
          acc -> {:cont, Enum.reverse(acc), []}
        end
      )

    data = for {_n, {off, gen}} <- sorted, into: <<>>, do: <<1, off::32, gen::16>>

    dict =
      trailer
      |> Map.merge(%{
        "Type" => "XRef",
        "Size" => size,
        "W" => [1, 4, 2],
        "Index" => Enum.flat_map(index, fn [{first, _} | _] = run -> [first, length(run)] end)
      })

    obj = Serializer.serialize(%Stream{dict: dict, raw: data})

    [
      Integer.to_string(num),
      " 0 obj\n",
      obj,
      "\nendobj\nstartxref\n",
      Integer.to_string(pos),
      "\n%%EOF\n"
    ]
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  @doc "The offset after the last `startxref` keyword."
  @spec startxref(binary()) :: {:ok, non_neg_integer()} | :error
  def startxref(data) do
    tail_start = max(byte_size(data) - 2048, 0)
    tail = binary_part(data, tail_start, byte_size(data) - tail_start)

    case :binary.matches(tail, "startxref") do
      [] ->
        :error

      matches ->
        {p, l} = List.last(matches)

        case tail
             |> binary_part(p + l, byte_size(tail) - p - l)
             |> Parser.skip_ws()
             |> Parser.parse_number() do
          {n, _} when is_integer(n) -> {:ok, n}
          _ -> :error
        end
    end
  end

  defp xref_stream?(data, offset) do
    rest = data |> binary_part(offset, byte_size(data) - offset) |> Parser.skip_ws()
    not String.starts_with?(rest, "xref")
  end
end
