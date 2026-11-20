defmodule EmbedPdf.Render.CCITT do
  @moduledoc """
  CCITT fax decoding (ITU-T T.4 and T.6) for `CCITTFaxDecode` images:
  Group 4 (`/K < 0`), Group 3 one-dimensional (`/K 0`) and Group 3
  two-dimensional (`/K > 0`), with `EncodedByteAlign`, `EndOfLine` and
  `BlackIs1`.

  Output rows are packed 1-bit samples; following PDF, black is 0 unless
  `/BlackIs1 true`. Damaged data yields the rows decoded so far, padded
  with white. No more rows are produced than fit in `max_bytes`.
  """

  @max_bytes 64_000_000

  # {bits as string, run length}
  @white_codes [
    {"00110101", 0},
    {"000111", 1},
    {"0111", 2},
    {"1000", 3},
    {"1011", 4},
    {"1100", 5},
    {"1110", 6},
    {"1111", 7},
    {"10011", 8},
    {"10100", 9},
    {"00111", 10},
    {"01000", 11},
    {"001000", 12},
    {"000011", 13},
    {"110100", 14},
    {"110101", 15},
    {"101010", 16},
    {"101011", 17},
    {"0100111", 18},
    {"0001100", 19},
    {"0001000", 20},
    {"0010111", 21},
    {"0000011", 22},
    {"0000100", 23},
    {"0101000", 24},
    {"0101011", 25},
    {"0010011", 26},
    {"0100100", 27},
    {"0011000", 28},
    {"00000010", 29},
    {"00000011", 30},
    {"00011010", 31},
    {"00011011", 32},
    {"00010010", 33},
    {"00010011", 34},
    {"00010100", 35},
    {"00010101", 36},
    {"00010110", 37},
    {"00010111", 38},
    {"00101000", 39},
    {"00101001", 40},
    {"00101010", 41},
    {"00101011", 42},
    {"00101100", 43},
    {"00101101", 44},
    {"00000100", 45},
    {"00000101", 46},
    {"00001010", 47},
    {"00001011", 48},
    {"01010010", 49},
    {"01010011", 50},
    {"01010100", 51},
    {"01010101", 52},
    {"00100100", 53},
    {"00100101", 54},
    {"01011000", 55},
    {"01011001", 56},
    {"01011010", 57},
    {"01011011", 58},
    {"01001010", 59},
    {"01001011", 60},
    {"00110010", 61},
    {"00110011", 62},
    {"00110100", 63},
    {"11011", 64},
    {"10010", 128},
    {"010111", 192},
    {"0110111", 256},
    {"00110110", 320},
    {"00110111", 384},
    {"01100100", 448},
    {"01100101", 512},
    {"01101000", 576},
    {"01100111", 640},
    {"011001100", 704},
    {"011001101", 768},
    {"011010010", 832},
    {"011010011", 896},
    {"011010100", 960},
    {"011010101", 1024},
    {"011010110", 1088},
    {"011010111", 1152},
    {"011011000", 1216},
    {"011011001", 1280},
    {"011011010", 1344},
    {"011011011", 1408},
    {"010011000", 1472},
    {"010011001", 1536},
    {"010011010", 1600},
    {"011000", 1664},
    {"010011011", 1728}
  ]

  @black_codes [
    {"0000110111", 0},
    {"010", 1},
    {"11", 2},
    {"10", 3},
    {"011", 4},
    {"0011", 5},
    {"0010", 6},
    {"00011", 7},
    {"000101", 8},
    {"000100", 9},
    {"0000100", 10},
    {"0000101", 11},
    {"0000111", 12},
    {"00000100", 13},
    {"00000111", 14},
    {"000011000", 15},
    {"0000010111", 16},
    {"0000011000", 17},
    {"0000001000", 18},
    {"00001100111", 19},
    {"00001101000", 20},
    {"00001101100", 21},
    {"00000110111", 22},
    {"00000101000", 23},
    {"00000010111", 24},
    {"00000011000", 25},
    {"000011001010", 26},
    {"000011001011", 27},
    {"000011001100", 28},
    {"000011001101", 29},
    {"000001101000", 30},
    {"000001101001", 31},
    {"000001101010", 32},
    {"000001101011", 33},
    {"000011010010", 34},
    {"000011010011", 35},
    {"000011010100", 36},
    {"000011010101", 37},
    {"000011010110", 38},
    {"000011010111", 39},
    {"000001101100", 40},
    {"000001101101", 41},
    {"000011011010", 42},
    {"000011011011", 43},
    {"000001010100", 44},
    {"000001010101", 45},
    {"000001010110", 46},
    {"000001010111", 47},
    {"000001100100", 48},
    {"000001100101", 49},
    {"000001010010", 50},
    {"000001010011", 51},
    {"000000100100", 52},
    {"000000110111", 53},
    {"000000111000", 54},
    {"000000100111", 55},
    {"000000101000", 56},
    {"000001011000", 57},
    {"000001011001", 58},
    {"000000101011", 59},
    {"000000101100", 60},
    {"000001011010", 61},
    {"000001100110", 62},
    {"000001100111", 63},
    {"0000001111", 64},
    {"000011001000", 128},
    {"000011001001", 192},
    {"000001011011", 256},
    {"000000110011", 320},
    {"000000110100", 384},
    {"000000110101", 448},
    {"0000001101100", 512},
    {"0000001101101", 576},
    {"0000001001010", 640},
    {"0000001001011", 704},
    {"0000001001100", 768},
    {"0000001001101", 832},
    {"0000001110010", 896},
    {"0000001110011", 960},
    {"0000001110100", 1024},
    {"0000001110101", 1088},
    {"0000001110110", 1152},
    {"0000001110111", 1216},
    {"0000001010010", 1280},
    {"0000001010011", 1344},
    {"0000001010100", 1408},
    {"0000001010101", 1472},
    {"0000001011010", 1536},
    {"0000001011011", 1600},
    {"0000001100100", 1664},
    {"0000001100101", 1728}
  ]

  @extended [
    {"00000001000", 1792},
    {"00000001100", 1856},
    {"00000001101", 1920},
    {"000000010010", 1984},
    {"000000010011", 2048},
    {"000000010100", 2112},
    {"000000010101", 2176},
    {"000000010110", 2240},
    {"000000010111", 2304},
    {"000000011100", 2368},
    {"000000011101", 2432},
    {"000000011110", 2496},
    {"000000011111", 2560}
  ]

  to_key = fn {bits, run} -> {{String.length(bits), String.to_integer(bits, 2)}, run} end
  @white Map.new(@white_codes ++ @extended, to_key)
  @black Map.new(@black_codes ++ @extended, to_key)

  @doc """
  Decodes CCITT data for a `width` × `height` image (`params` is the
  `DecodeParms` dictionary). Returns packed rows, `max_bytes` of them at
  most (default #{@max_bytes}).
  """
  @spec decode(binary(), map(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | :error
  def decode(data, params, width, height, max_bytes \\ @max_bytes) do
    k = int(params["K"], 0)
    columns = int(params["Columns"], 1728)
    columns = if columns > 0, do: columns, else: width
    rows = int(params["Rows"], 0)
    rows = if rows > 0, do: rows, else: height
    black_is_1 = params["BlackIs1"] == true
    align? = params["EncodedByteAlign"] == true

    if columns <= 0 or rows <= 0 or columns > 100_000 do
      :error
    else
      row_bytes = div(columns + 7, 8)
      rows = min(rows, div(max_bytes, row_bytes))
      # rows are packed as they come: their changing elements take far more
      packed = decode_lines(data, k, columns, rows, align?, &pack(&1, columns, black_is_1))
      white = if black_is_1, do: 0, else: 0xFF
      # the rows the data did not give are white
      blank = :binary.copy(<<white>>, row_bytes * max(rows - length(packed), 0))

      {:ok, IO.iodata_to_binary([packed, blank])}
    end
  rescue
    _ -> :error
  end

  defp int(v, _default) when is_integer(v), do: v
  defp int(_, default), do: default

  # ---------------------------------------------------------------- lines

  defp decode_lines(data, k, columns, rows, align?, pack) do
    initial_ref = [columns, columns]
    loop(data, k, columns, rows, align?, initial_ref, [], 0, pack)
  end

  defp loop(_bits, _k, _columns, rows, _align?, _ref, acc, n, _pack) when n >= rows,
    do: Enum.reverse(acc)

  defp loop(bits, k, columns, rows, align?, ref, acc, n, pack) do
    bits = if align? and k < 0, do: align(bits), else: bits

    result =
      cond do
        k < 0 ->
          decode_2d(bits, ref, columns)

        true ->
          bits = skip_eol(bits)

          {mode, bits} =
            if k > 0 do
              case bits do
                <<1::1, rest::bitstring>> -> {:one_d, rest}
                <<0::1, rest::bitstring>> -> {:two_d, rest}
                _ -> {:eof, bits}
              end
            else
              {:one_d, bits}
            end

          case mode do
            :one_d -> decode_1d(bits, columns)
            :two_d -> decode_2d(bits, ref, columns)
            :eof -> :eof
          end
      end

    case result do
      {:ok, changes, rest} ->
        loop(
          rest,
          k,
          columns,
          rows,
          align?,
          changes ++ [columns, columns],
          [pack.(changes) | acc],
          n + 1,
          pack
        )

      _ ->
        Enum.reverse(acc)
    end
  end

  defp align(bits) do
    pad = rem(bit_size(bits), 8)
    <<_::size(pad), rest::bitstring>> = bits
    rest
  end

  # an EOL is 11+ zero bits (fill bits included, which also covers
  # EncodedByteAlign) followed by a one
  defp skip_eol(<<0::11, rest::bitstring>> = bits) do
    case drop_zeros(rest) do
      <<1::1, rest2::bitstring>> -> skip_eol(rest2)
      _ -> bits
    end
  end

  defp skip_eol(bits), do: bits

  defp drop_zeros(<<0::1, rest::bitstring>>), do: drop_zeros(rest)
  defp drop_zeros(bits), do: bits

  # ---------------------------------------------------------------- 1D (Modified Huffman)

  defp decode_1d(bits, columns), do: one_d(bits, columns, 0, :white, [])

  defp one_d(bits, columns, pos, _color, changes) when pos >= columns,
    do: {:ok, Enum.reverse(changes), bits}

  defp one_d(bits, columns, pos, color, changes) do
    case run(bits, color, 0) do
      {:ok, len, rest} ->
        pos = min(pos + len, columns)
        one_d(rest, columns, pos, flip(color), [pos | changes])

      :error ->
        if changes == [], do: :error, else: {:ok, Enum.reverse(changes), <<>>}
    end
  end

  # ---------------------------------------------------------------- 2D (READ / MMR)

  # `ref` is what is left of the reference line's changing elements to the
  # right of a0 (they are in order and a0 only moves right), `i` the index
  # of its first one, modulo 2.
  defp decode_2d(bits, ref, columns), do: two_d(bits, ref, 0, columns, -1, :white, [])

  defp two_d(bits, _ref, _i, columns, a0, _color, changes) when a0 >= columns,
    do: {:ok, Enum.reverse(changes), bits}

  defp two_d(bits, [x | ref], i, columns, a0, color, changes) when x <= a0,
    do: two_d(bits, ref, 1 - i, columns, a0, color, changes)

  defp two_d(bits, ref, i, columns, a0, color, changes) do
    {b1, b2} = b1_b2(ref, i, color)

    case mode(bits) do
      {:pass, rest} ->
        two_d(rest, ref, i, columns, b2, color, changes)

      {:horizontal, rest} ->
        start = max(a0, 0)

        with {:ok, r1, rest} <- run(rest, color, 0),
             {:ok, r2, rest} <- run(rest, flip(color), 0) do
          a1 = min(start + r1, columns)
          a2 = min(a1 + r2, columns)
          two_d(rest, ref, i, columns, a2, color, [a2, a1 | changes])
        else
          _ -> partial(changes)
        end

      {{:vertical, d}, rest} ->
        # a changing element can never move left of a0
        a1 = (b1 + d) |> max(0) |> min(columns) |> max(a0)
        two_d(rest, ref, i, columns, a1, flip(color), [a1 | changes])

      :eol ->
        partial(changes)

      :error ->
        partial(changes)
    end
  end

  defp partial([]), do: :error
  defp partial(changes), do: {:ok, Enum.reverse(changes), <<>>}

  # b1: first changing element on the reference line to the right of a0 whose
  # color is the opposite of a0's (changes at even indices turn black)
  # Every element of `ref` is to the right of a0, so b1 is its first or its
  # second one; b2 is the element after b1.
  defp b1_b2(ref, i, color) do
    want = if color == :white, do: 0, else: 1

    case ref do
      [b1 | rest] when i == want -> {b1, b2(rest, b1)}
      [_, b1 | rest] when i != want -> {b1, b2(rest, b1)}
      _ -> {100_000_000, 100_000_000}
    end
  end

  defp b2([x | _], _b1), do: x
  defp b2([], b1), do: b1

  defp mode(<<1::1, rest::bitstring>>), do: {{:vertical, 0}, rest}
  defp mode(<<0b011::3, rest::bitstring>>), do: {{:vertical, 1}, rest}
  defp mode(<<0b010::3, rest::bitstring>>), do: {{:vertical, -1}, rest}
  defp mode(<<0b001::3, rest::bitstring>>), do: {:horizontal, rest}
  defp mode(<<0b0001::4, rest::bitstring>>), do: {:pass, rest}
  defp mode(<<0b000011::6, rest::bitstring>>), do: {{:vertical, 2}, rest}
  defp mode(<<0b000010::6, rest::bitstring>>), do: {{:vertical, -2}, rest}
  defp mode(<<0b0000011::7, rest::bitstring>>), do: {{:vertical, 3}, rest}
  defp mode(<<0b0000010::7, rest::bitstring>>), do: {{:vertical, -3}, rest}
  defp mode(<<0::11, _::bitstring>>), do: :eol
  defp mode(_), do: :error

  defp flip(:white), do: :black
  defp flip(:black), do: :white

  # ---------------------------------------------------------------- run lengths

  # sums make-up codes until a terminating code (< 64)
  defp run(bits, color, total) do
    table = if color == :white, do: @white, else: @black

    case code(bits, table, 0, 0) do
      {:ok, len, rest} when len < 64 -> {:ok, total + len, rest}
      {:ok, len, rest} -> run(rest, color, total + len)
      :error -> :error
    end
  end

  defp code(_bits, _table, _value, len) when len >= 13, do: :error

  defp code(<<b::1, rest::bitstring>>, table, value, len) do
    value = value * 2 + b
    len = len + 1

    case Map.fetch(table, {len, value}) do
      {:ok, run} -> {:ok, run, rest}
      :error -> code(rest, table, value, len)
    end
  end

  defp code(_, _table, _value, _len), do: :error

  # ---------------------------------------------------------------- packing

  # changes: positions where the color flips, starting from white
  defp pack(changes, columns, black_is_1) do
    {white_bit, black_bit} = if black_is_1, do: {0, 1}, else: {1, 0}

    {segments, last, color} =
      Enum.reduce(changes, {[], 0, :white}, fn pos, {segs, prev, color} ->
        pos = pos |> max(prev) |> min(columns)
        bit = if color == :white, do: white_bit, else: black_bit
        {[fill(bit, pos - prev) | segs], pos, flip(color)}
      end)

    tail_bit = if color == :white, do: white_bit, else: black_bit
    segments = [fill(tail_bit, columns - last) | segments]
    bits = segments |> Enum.reverse() |> :erlang.list_to_bitstring()
    pad = rem(8 - rem(bit_size(bits), 8), 8)
    <<bits::bitstring, 0::size(pad)>>
  end

  defp fill(_bit, n) when n <= 0, do: <<>>
  defp fill(1, n), do: <<-1::size(n)>>
  defp fill(0, n), do: <<0::size(n)>>
end
