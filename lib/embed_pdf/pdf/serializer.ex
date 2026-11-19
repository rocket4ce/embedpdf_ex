defmodule EmbedPdf.PDF.Serializer do
  @moduledoc """
  Writes objects back to PDF syntax and whole documents to bytes.

  `save/2` writes a fresh, unencrypted file holding only the objects still
  reachable from the trailer, with a classic cross-reference table: the
  simplest output every reader accepts.
  """

  alias EmbedPdf.PDF.{Document, Filter, Stream}

  @doc "Serializes one object value to iodata."
  @spec serialize(term()) :: iodata()
  def serialize(nil), do: "null"
  def serialize(true), do: "true"
  def serialize(false), do: "false"
  def serialize(n) when is_integer(n), do: Integer.to_string(n)
  def serialize(f) when is_float(f), do: format_real(f)
  def serialize({:ref, n, g}), do: [Integer.to_string(n), " ", Integer.to_string(g), " R"]
  def serialize({:string, s}), do: serialize_string(s)
  def serialize({:hex, s}), do: ["<", Base.encode16(s), ">"]
  def serialize(name) when is_binary(name), do: serialize_name(name)

  def serialize(list) when is_list(list),
    do: ["[", list |> Enum.map(&serialize/1) |> Enum.intersperse(" "), "]"]

  def serialize(%Stream{dict: dict, raw: raw}) do
    dict = Map.put(dict, "Length", byte_size(raw))
    [serialize(dict), "\nstream\n", raw, "\nendstream"]
  end

  def serialize(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(fn {k, _} -> sort_key(k) end)
      |> Enum.map(fn {k, v} -> [serialize_name(k), " ", serialize(v)] end)
      |> Enum.intersperse("\n")

    ["<<", entries, ">>"]
  end

  defp sort_key("Type"), do: {0, ""}
  defp sort_key("Subtype"), do: {1, ""}
  defp sort_key(k), do: {2, k}

  @doc "Formats a real number compactly (no exponent)."
  @spec format_real(number()) :: String.t()
  def format_real(f) when is_integer(f), do: Integer.to_string(f)

  def format_real(f) do
    if f == Float.round(f) and abs(f) < 1.0e15 do
      f |> trunc() |> Integer.to_string()
    else
      f
      |> :erlang.float_to_binary(decimals: 5)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
      |> then(fn
        "-0" -> "0"
        s -> s
      end)
    end
  end

  defp serialize_name(name) do
    escaped =
      for <<c <- name>>, into: <<>> do
        if c < 33 or c > 126 or c in ~c"#()<>[]{}/%",
          do: "#" <> Base.encode16(<<c>>),
          else: <<c>>
      end

    ["/", escaped]
  end

  defp serialize_string(s) do
    printable =
      for(<<c <- s>>, do: c) |> Enum.count(fn c -> c in 32..126 or c in [9, 10, 13] end)

    if byte_size(s) > 0 and printable < byte_size(s) * 0.9 do
      ["<", Base.encode16(s), ">"]
    else
      escaped =
        for <<c <- s>>, into: <<>> do
          case c do
            ?( ->
              "\\("

            ?) ->
              "\\)"

            ?\\ ->
              "\\\\"

            ?\r ->
              "\\r"

            ?\n ->
              "\\n"

            c when c < 32 or c > 126 ->
              "\\" <> String.pad_leading(Integer.to_string(c, 8), 3, "0")

            c ->
              <<c>>
          end
        end

      ["(", escaped, ")"]
    end
  end

  @doc """
  Serializes a whole document. Options:

    * `:compress` – deflate uncompressed streams (default true)
    * `:garbage_collect` – drop unreachable objects (default true)
  """
  @spec save(Document.t(), keyword()) :: binary()
  def save(%Document{} = doc, opts \\ []) do
    compress? = Keyword.get(opts, :compress, true)
    gc? = Keyword.get(opts, :garbage_collect, true)

    trailer = Map.take(doc.trailer, ["Root", "Info", "ID"])

    nums =
      if gc?,
        do: reachable(doc, trailer),
        else: doc.objects |> Map.keys() |> MapSet.new()

    # renumber densely so the table stays small
    order = nums |> Enum.sort()
    mapping = order |> Enum.with_index(1) |> Map.new()

    header = ["%PDF-", max_version(doc.version), "\n%", <<0xE2, 0xE3, 0xCF, 0xD3>>, "\n"]
    header_bin = IO.iodata_to_binary(header)

    {chunks, offsets, _pos} =
      Enum.reduce(order, {[], [], byte_size(header_bin)}, fn num, {chunks, offsets, pos} ->
        value = doc.objects |> Map.fetch!(num) |> renumber(mapping) |> prepare_stream(compress?)

        chunk =
          IO.iodata_to_binary([
            Integer.to_string(mapping[num]),
            " 0 obj\n",
            serialize(value),
            "\nendobj\n"
          ])

        {[chunk | chunks], [pos | offsets], pos + byte_size(chunk)}
      end)

    body = Enum.reverse(chunks)
    offsets = Enum.reverse(offsets)
    xref_pos = byte_size(header_bin) + Enum.reduce(body, 0, &(byte_size(&1) + &2))
    size = length(order) + 1

    xref = [
      "xref\n0 ",
      Integer.to_string(size),
      "\n0000000000 65535 f \n",
      Enum.map(offsets, fn off ->
        [String.pad_leading(Integer.to_string(off), 10, "0"), " 00000 n \n"]
      end)
    ]

    trailer =
      trailer
      |> renumber(mapping)
      |> Map.put("Size", size)
      |> Map.put_new_lazy("ID", fn ->
        id = :crypto.strong_rand_bytes(16)
        [{:string, id}, {:string, id}]
      end)

    IO.iodata_to_binary([
      header_bin,
      body,
      xref,
      "trailer\n",
      serialize(trailer),
      "\nstartxref\n",
      Integer.to_string(xref_pos),
      "\n%%EOF\n"
    ])
  end

  defp max_version(v) when v in ["1.0", "1.1", "1.2", "1.3", "1.4"], do: "1.7"
  defp max_version(v) when is_binary(v), do: v
  defp max_version(_), do: "1.7"

  defp prepare_stream(%Stream{dict: dict, raw: raw} = s, true) do
    if dict["Filter"] in [nil, []] and byte_size(raw) > 64 do
      %{
        s
        | dict: Map.put(dict, "Filter", "FlateDecode") |> Map.delete("DecodeParms"),
          raw: Filter.deflate(raw)
      }
    else
      s
    end
  end

  defp prepare_stream(value, _), do: value

  defp renumber({:ref, n, _}, mapping) do
    case mapping do
      %{^n => m} -> {:ref, m, 0}
      _ -> nil
    end
  end

  defp renumber(list, mapping) when is_list(list), do: Enum.map(list, &renumber(&1, mapping))
  defp renumber(%Stream{dict: d} = s, mapping), do: %{s | dict: renumber(d, mapping)}

  defp renumber(map, mapping) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, renumber(v, mapping)} end)

  defp renumber(v, _), do: v

  @doc "Object numbers reachable from `root` values."
  @spec reachable(Document.t(), term()) :: MapSet.t()
  def reachable(doc, root), do: mark(doc, [root], MapSet.new())

  defp mark(_doc, [], seen), do: seen

  defp mark(doc, [value | rest], seen) do
    case value do
      {:ref, n, _} ->
        if MapSet.member?(seen, n) or not Map.has_key?(doc.objects, n),
          do: mark(doc, rest, seen),
          else: mark(doc, [doc.objects[n] | rest], MapSet.put(seen, n))

      %Stream{dict: d} ->
        mark(doc, [d | rest], seen)

      list when is_list(list) ->
        mark(doc, list ++ rest, seen)

      map when is_map(map) ->
        mark(doc, Map.values(map) ++ rest, seen)

      _ ->
        mark(doc, rest, seen)
    end
  end
end
