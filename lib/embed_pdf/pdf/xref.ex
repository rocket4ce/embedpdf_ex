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

  # A file has one section per incremental save; more than this is a loop
  # or a bomb.
  @max_sections 1024

  # PDFium's limit on object numbers; entries beyond it are not read. A
  # small file gets fewer still (see max_entries/1): a few bytes of
  # cross-reference stream can announce millions of objects.
  @max_objects 4_194_304

  @doc "Returns `{entries, trailer, reconstructed?}`."
  @spec load(binary()) :: {%{non_neg_integer() => entry()}, map(), boolean()}
  def load(data) do
    with {:ok, start} <- find_startxref(data),
         {:ok, entries, trailer, _state} <- read_chain(data, start, %{}, nil, new_state(data)),
         true <- Map.has_key?(trailer, "Root"),
         true <- plausible?(data, entries) do
      {entries, trailer, false}
    else
      _ -> reconstruct(data)
    end
  end

  # What following the chain of sections has cost so far: the offsets
  # visited (each section is read once, however many `/Prev` and `/XRefStm`
  # point at it), and what is left of the bytes that may be parsed and
  # decoded.
  defp new_state(data) do
    %{
      seen: MapSet.new(),
      parse: work_budget(data),
      decode: decode_budget(data),
      max_entries: max_entries(data)
    }
  end

  # no file has more objects than a few per byte
  defp max_entries(data),
    do: data |> byte_size() |> Kernel.*(4) |> max(65_536) |> min(@max_objects)

  @doc false
  # Bytes that may be parsed while loading the objects of a file: several
  # times its size, so only objects that overlap each other run out.
  def work_budget(data), do: 8 * byte_size(data) + 1_000_000

  @doc false
  # Bytes that the cross-reference and object streams of a file may decode
  # to, all together.
  def decode_budget(data), do: max(Filter.max_bytes(), 32 * byte_size(data))

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

  # Returns `{:ok, entries, trailer, state}` or `{:error, state}`.
  defp read_chain(_data, nil, entries, trailer, state), do: {:ok, entries, trailer || %{}, state}

  defp read_chain(data, offset, entries, trailer, state) do
    if offset < 0 or offset >= byte_size(data) or MapSet.member?(state.seen, offset) or
         MapSet.size(state.seen) >= @max_sections or map_size(entries) >= state.max_entries do
      {:ok, entries, trailer || %{}, state}
    else
      state = %{state | seen: MapSet.put(state.seen, offset)}
      rest = binary_part(data, offset, byte_size(data) - offset) |> Parser.skip_ws()

      {result, state} =
        if String.starts_with?(rest, "xref"),
          do: {read_table(binary_part(rest, 4, byte_size(rest) - 4)), state},
          else: read_stream(rest, state)

      case result do
        {:ok, section, section_trailer} ->
          # entries already known come from a newer section and win
          entries = Map.merge(section, entries)

          {entries, state} =
            case section_trailer["XRefStm"] do
              stm when is_integer(stm) ->
                case read_chain(data, stm, %{}, nil, state) do
                  {:ok, stm_entries, _, state} -> {Map.merge(stm_entries, entries), state}
                  {:error, state} -> {entries, state}
                end

              _ ->
                {entries, state}
            end

          trailer = trailer || section_trailer
          prev = section_trailer["Prev"]
          prev = if is_integer(prev), do: prev, else: nil
          read_chain(data, prev, entries, trailer, state)

        :error ->
          if trailer, do: {:ok, entries, trailer, state}, else: {:error, state}
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
        # anything but `start count` ends the table: read as numbers, junk
        # would be 0 0 and never be passed
        with {start, r1} when is_integer(start) <- unsigned(rest),
             {count, r2} when is_integer(count) <- unsigned(Parser.skip_ws(r1)) do
          {acc, r3} = read_entries(r2, start, count, acc)
          read_subsections(r3, acc)
        else
          _ -> :error
        end
    end
  end

  defp unsigned(<<c, _::binary>> = input) when c in ?0..?9, do: Parser.parse_number(input)
  defp unsigned(_), do: :error

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

  defp read_stream(rest, state) do
    {parsed, parse} = Parser.parse_indirect_within(rest, fn _ -> nil end, state.parse)
    state = %{state | parse: parse}

    with {:ok, _num, _gen, %Stream{dict: dict, raw: raw}} <- parsed,
         true <- dict["Type"] == "XRef" or is_map_key(dict, "W") do
      {decoded, state} = decode(raw, dict, state)
      {{:ok, parse_xref_stream(dict, decoded, state.max_entries), dict}, state}
    else
      _ -> {:error, state}
    end
  end

  # What a section decodes to comes off what the whole chain may decode to,
  # and is no more than the entries that will be read of it (each up to 24
  # bytes, and a predictor byte).
  defp decode(raw, dict, state) do
    limit = state.decode |> min(Filter.max_bytes()) |> min(state.max_entries * 25 + 4096)

    case Filter.decode_within(raw, dict["Filter"], dict["DecodeParms"], limit) do
      {:ok, {decoded, _}} -> {decoded, %{state | decode: state.decode - byte_size(decoded)}}
      :too_large -> {<<>>, %{state | decode: state.decode - limit}}
    end
  end

  @doc false
  # The entries of a cross-reference stream. `/Size` and `/Index` only say
  # how many entries to expect: what is read is what the data holds.
  def parse_xref_stream(dict, data, max_entries \\ @max_objects) do
    [w1, w2, w3] = widths(dict["W"])
    entry_len = w1 + w2 + w3
    size = dict["Size"]

    index =
      case dict["Index"] do
        list when is_list(list) -> Enum.chunk_every(list, 2, 2, :discard)
        _ -> [[0, size]]
      end

    if entry_len == 0 or Enum.max([w1, w2, w3]) > 8 do
      %{}
    else
      {acc, _data} =
        Enum.reduce(index, {%{}, data}, fn
          [start, count], {acc, data} when is_integer(start) and is_integer(count) ->
            room = max(max_entries - map_size(acc), 0)
            count = count |> min(div(byte_size(data), entry_len)) |> min(room)
            read_stream_entries(data, start, count, {w1, w2, w3}, acc)

          _, state ->
            state
        end)

      acc
    end
  end

  defp read_stream_entries(data, _num, count, _widths, acc) when count <= 0, do: {acc, data}

  defp read_stream_entries(data, num, count, {w1, w2, w3} = widths, acc) do
    <<f1::size(w1)-unit(8), f2::size(w2)-unit(8), f3::size(w3)-unit(8), rest::binary>> = data
    type = if w1 == 0, do: 1, else: f1

    value =
      case type do
        0 -> :free
        1 -> {:offset, f2, f3}
        2 -> {:compressed, f2, f3}
        _ -> nil
      end

    acc = if value && not Map.has_key?(acc, num), do: Map.put(acc, num, value), else: acc
    read_stream_entries(rest, num + 1, count - 1, widths, acc)
  end

  defp widths(list) when is_list(list) do
    list
    |> Enum.take(3)
    |> Enum.map(&if(is_integer(&1) and &1 > 0, do: &1, else: 0))
    |> pad3()
  end

  defp widths(_), do: [1, 2, 1]

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
    # every candidate is parsed from where it starts, so candidates that
    # overlap share a budget of bytes
    {plain, budget} =
      :binary.matches(data, "trailer")
      |> Enum.reduce({[], work_budget(data)}, fn
        _match, {acc, budget} when budget <= 0 ->
          {acc, budget}

        {pos, len}, {acc, budget} ->
          from = pos + len
          window = binary_part(data, from, min(byte_size(data) - from, budget))

          case Parser.parse_value(window) do
            {dict, rest} when is_map(dict) -> {[dict | acc], budget - used(window, rest)}
            {_, rest} -> {acc, budget - used(window, rest)}
            :eof -> {acc, budget - used(window, <<>>)}
          end
      end)

    {streams, _budget} =
      :binary.matches(data, "/XRef")
      |> Enum.reduce({[], budget}, fn
        _match, {acc, budget} when budget <= 0 ->
          {acc, budget}

        {pos, _}, {acc, budget} ->
          # walk back to the start of the object holding this dictionary
          from = max(pos - 1024, 0)
          window = binary_part(data, from, pos - from)
          budget = budget - byte_size(window) - 1

          case Regex.scan(~r/\d+\s+\d+\s+obj/, window, return: :index) |> List.last() do
            [{s, _}] ->
              object = binary_part(data, from + s, byte_size(data) - from - s)

              case Parser.parse_indirect_within(object, fn _ -> nil end, budget) do
                {{:ok, _, _, %Stream{dict: dict}}, budget} -> {[dict | acc], budget}
                {_, budget} -> {acc, budget}
              end

            _ ->
              {acc, budget}
          end
      end)

    Enum.reverse(plain) ++ Enum.reverse(streams)
  end

  defp used(window, rest), do: max(byte_size(window) - byte_size(rest), 1)

  defp find_catalog_trailer(data, entries) do
    entries
    |> Enum.reduce_while(work_budget(data), fn {num, {:offset, off, gen}}, budget ->
      object = binary_part(data, off, byte_size(data) - off)

      case Parser.parse_indirect_within(object, fn _ -> nil end, budget) do
        {{:ok, ^num, _, %{"Type" => "Catalog"}}, _} -> {:halt, %{"Root" => {:ref, num, gen}}}
        {_, budget} when budget > 0 -> {:cont, budget}
        {_, budget} -> {:halt, budget}
      end
    end)
    |> then(&if is_map(&1), do: &1)
  end
end
