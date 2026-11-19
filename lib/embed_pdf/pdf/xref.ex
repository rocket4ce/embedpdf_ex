defmodule EmbedPdf.PDF.Xref do
  @moduledoc """
  Cross-reference loading: classic tables, cross-reference streams, hybrid
  files and incremental updates (`/Prev`). When the table is missing or
  broken the file is scanned for objects instead, the way PDFium does.

  Entries map an object number to `{:offset, byte_offset, gen}`,
  `{:compressed, object_stream_number, index}` or `:free`.
  """

  alias EmbedPdf.PDF.{Filter, Parser, Stream}

  @type entry ::
          {:offset, non_neg_integer(), non_neg_integer()}
          | {:compressed, pos_integer(), non_neg_integer()}
          | :free

  @doc "Returns `{entries, trailer, reconstructed?}`."
  @spec load(binary()) :: {%{non_neg_integer() => entry()}, map(), boolean()}
  def load(data) do
    with {:ok, start} <- find_startxref(data),
         {:ok, entries, trailer} <- read_chain(data, start, %{}, nil, MapSet.new()),
         true <- Map.has_key?(trailer, "Root"),
         true <- plausible?(data, entries) do
      {entries, trailer, false}
    else
      _ -> reconstruct(data)
    end
  end

  defp find_startxref(data) do
    size = byte_size(data)
    tail_start = max(size - 4096, 0)
    tail = binary_part(data, tail_start, size - tail_start)

    case :binary.matches(tail, "startxref") do
      [] ->
        :error

      matches ->
        {pos, len} = List.last(matches)
        rest = binary_part(tail, pos + len, byte_size(tail) - pos - len) |> Parser.skip_ws()

        case Parser.parse_number(rest) do
          {n, _} when is_integer(n) and n >= 0 and n < size -> {:ok, n}
          _ -> :error
        end
    end
  end

  defp read_chain(_data, nil, entries, trailer, _seen), do: {:ok, entries, trailer || %{}}

  defp read_chain(data, offset, entries, trailer, seen) do
    if MapSet.member?(seen, offset) or offset >= byte_size(data) do
      {:ok, entries, trailer || %{}}
    else
      seen = MapSet.put(seen, offset)
      rest = binary_part(data, offset, byte_size(data) - offset) |> Parser.skip_ws()

      result =
        if String.starts_with?(rest, "xref"),
          do: read_table(binary_part(rest, 4, byte_size(rest) - 4)),
          else: read_stream(data, rest)

      case result do
        {:ok, section, section_trailer} ->
          # entries already known come from a newer section and win
          entries = Map.merge(section, entries)

          entries =
            case section_trailer["XRefStm"] do
              stm when is_integer(stm) ->
                case read_chain(data, stm, %{}, nil, seen) do
                  {:ok, stm_entries, _} -> Map.merge(stm_entries, entries)
                  _ -> entries
                end

              _ ->
                entries
            end

          trailer = trailer || section_trailer
          prev = section_trailer["Prev"]
          prev = if is_integer(prev), do: prev, else: nil
          read_chain(data, prev, entries, trailer, seen)

        :error ->
          if trailer, do: {:ok, entries, trailer}, else: :error
      end
    end
  end

  defp read_table(input) do
    read_subsections(input, %{})
  end

  defp read_subsections(input, acc) do
    rest = Parser.skip_ws(input)

    cond do
      String.starts_with?(rest, "trailer") ->
        case Parser.parse_value(binary_part(rest, 7, byte_size(rest) - 7)) do
          {trailer, _} when is_map(trailer) -> {:ok, acc, trailer}
          _ -> :error
        end

      true ->
        with {start, r1} when is_integer(start) <- Parser.parse_number(rest),
             {count, r2} when is_integer(count) <- Parser.parse_number(Parser.skip_ws(r1)) do
          {acc, r3} = read_entries(r2, start, count, acc)
          read_subsections(r3, acc)
        else
          _ -> :error
        end
    end
  end

  defp read_entries(input, _num, 0, acc), do: {acc, input}

  defp read_entries(input, num, count, acc) do
    rest = Parser.skip_ws(input)

    with {offset, r1} when is_integer(offset) <- Parser.parse_number(rest),
         {gen, r2} when is_integer(gen) <- Parser.parse_number(Parser.skip_ws(r1)),
         <<type, r3::binary>> when type in [?n, ?f] <- Parser.skip_ws(r2) do
      entry = if type == ?n and offset > 0, do: {:offset, offset, gen}, else: :free
      acc = if Map.has_key?(acc, num), do: acc, else: Map.put(acc, num, entry)
      read_entries(r3, num + 1, count - 1, acc)
    else
      _ -> {acc, rest}
    end
  end

  defp read_stream(_data, rest) do
    case Parser.parse_indirect(rest) do
      {:ok, _num, _gen, %Stream{dict: %{"Type" => "XRef"} = dict, raw: raw}} ->
        decoded = Filter.decode!(raw, dict["Filter"], dict["DecodeParms"])
        {:ok, parse_xref_stream(dict, decoded), dict}

      {:ok, _num, _gen, %Stream{dict: dict, raw: raw}} when is_map_key(dict, "W") ->
        decoded = Filter.decode!(raw, dict["Filter"], dict["DecodeParms"])
        {:ok, parse_xref_stream(dict, decoded), dict}

      _ ->
        :error
    end
  end

  @doc false
  def parse_xref_stream(dict, data) do
    [w1, w2, w3] = dict |> Map.get("W", [1, 2, 1]) |> Enum.map(&max(&1 || 0, 0)) |> pad3()
    size = Map.get(dict, "Size", 0)
    index = Map.get(dict, "Index", [0, size]) |> Enum.chunk_every(2, 2, :discard)
    entry_len = w1 + w2 + w3

    {acc, _} =
      Enum.reduce(index, {%{}, data}, fn [start, count], {acc, data} ->
        Enum.reduce(0..(count - 1)//1, {acc, data}, fn i, {acc, data} ->
          case data do
            <<entry::binary-size(entry_len), rest::binary>> when entry_len > 0 ->
              <<f1::size(w1)-unit(8), f2::size(w2)-unit(8), f3::size(w3)-unit(8)>> = entry
              type = if w1 == 0, do: 1, else: f1

              value =
                case type do
                  0 -> :free
                  1 -> {:offset, f2, f3}
                  2 -> {:compressed, f2, f3}
                  _ -> nil
                end

              num = start + i

              acc =
                if value && not Map.has_key?(acc, num), do: Map.put(acc, num, value), else: acc

              {acc, rest}

            _ ->
              {acc, <<>>}
          end
        end)
      end)

    acc
  end

  defp pad3([a, b, c | _]), do: [a, b, c]
  defp pad3(list), do: pad3(list ++ [0])

  # Spot-check a few offsets; broken tables point into the middle of nowhere.
  defp plausible?(data, entries) do
    entries
    |> Enum.filter(fn {_, e} -> match?({:offset, _, _}, e) end)
    |> Enum.take_random(8)
    |> Enum.all?(fn {num, {:offset, off, _}} ->
      off < byte_size(data) and
        match?(
          {:ok, ^num, _, _},
          data |> binary_part(off, min(64, byte_size(data) - off)) |> header_only(num)
        )
    end)
  end

  defp header_only(chunk, _num) do
    rest = Parser.skip_ws(chunk)

    with {n, r} when is_integer(n) <- Parser.parse_number(rest),
         {g, r} when is_integer(g) <- Parser.parse_number(Parser.skip_ws(r)),
         <<"obj", _::binary>> <- Parser.skip_ws(r) do
      {:ok, n, g, nil}
    else
      _ -> :error
    end
  end

  # ---------------------------------------------------------------- reconstruction

  @doc "Rebuilds the cross-reference by scanning the file for `N G obj`."
  def reconstruct(data) do
    entries =
      ~r/(?<![0-9])(\d{1,10})[ \t\r\n\f\0]+(\d{1,5})[ \t\r\n\f\0]+obj/
      |> Regex.scan(data, return: :index, capture: :all)
      |> Enum.reduce(%{}, fn [{start, _}, {ns, nl}, {gs, gl}], acc ->
        num = String.to_integer(binary_part(data, ns, nl))
        gen = String.to_integer(binary_part(data, gs, gl))
        Map.put(acc, num, {:offset, start, gen})
      end)

    trailer =
      find_trailers(data)
      |> Enum.reverse()
      |> Enum.find(&Map.has_key?(&1, "Root"))

    trailer = trailer || find_catalog_trailer(data, entries)

    # objects inside object streams are found by expanding the streams later
    {entries, trailer || %{}, true}
  end

  defp find_trailers(data) do
    plain =
      :binary.matches(data, "trailer")
      |> Enum.flat_map(fn {pos, len} ->
        rest = binary_part(data, pos + len, byte_size(data) - pos - len)

        case Parser.parse_value(rest) do
          {dict, _} when is_map(dict) -> [dict]
          _ -> []
        end
      end)

    streams =
      :binary.matches(data, "/XRef")
      |> Enum.flat_map(fn {pos, _} ->
        # walk back to the start of the object holding this dictionary
        from = max(pos - 1024, 0)
        window = binary_part(data, from, pos - from)

        case Regex.scan(~r/\d+\s+\d+\s+obj/, window, return: :index) |> List.last() do
          [{s, _}] ->
            case Parser.parse_indirect(binary_part(data, from + s, byte_size(data) - from - s)) do
              {:ok, _, _, %Stream{dict: dict}} -> [dict]
              _ -> []
            end

          _ ->
            []
        end
      end)

    plain ++ streams
  end

  defp find_catalog_trailer(data, entries) do
    Enum.find_value(entries, fn {num, {:offset, off, gen}} ->
      case Parser.parse_indirect(binary_part(data, off, byte_size(data) - off)) do
        {:ok, ^num, _, %{"Type" => "Catalog"}} -> %{"Root" => {:ref, num, gen}}
        _ -> nil
      end
    end)
  end
end
