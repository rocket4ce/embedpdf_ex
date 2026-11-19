defmodule EmbedPdf.PDF.Filter do
  @moduledoc """
  Stream decoding filters (ISO 32000-1, 7.4).

  `decode/3` applies a stream's whole filter chain. Image codecs that the
  browser decodes itself (`DCTDecode`, `JPXDecode`) and the ones handled by
  the image pipeline (`JBIG2Decode`, `CCITTFaxDecode`) stop the chain and are
  reported back, so callers know what the remaining bytes are.
  """

  import Bitwise

  @image_filters ~w(DCTDecode DCT JPXDecode JBIG2Decode CCITTFaxDecode CCF)

  @doc """
  Decodes `data` through `filters` (a name or list of names) with their
  `params` (a dict, a list of dicts or nil).

  Returns `{decoded, nil}` when fully decoded, or `{partially_decoded,
  {image_filter, params}}` when an image filter remains.
  """
  @spec decode(binary(), term(), term()) :: {binary(), nil | {binary(), map()}}
  def decode(data, filters, params) do
    filters = List.wrap(filters)
    params = normalize_params(params, length(filters))
    run(data, Enum.zip(filters, params))
  end

  @doc "Decodes completely, leaving image-codec data as is."
  @spec decode!(binary(), term(), term()) :: binary()
  def decode!(data, filters, params), do: data |> decode(filters, params) |> elem(0)

  defp normalize_params(nil, n), do: List.duplicate(%{}, n)
  defp normalize_params(p, n) when is_map(p), do: [p | List.duplicate(%{}, max(n - 1, 0))]

  defp normalize_params(list, n) when is_list(list),
    do:
      Enum.map(list, &if(is_map(&1), do: &1, else: %{})) ++
        List.duplicate(%{}, max(n - length(list), 0))

  defp normalize_params(_, n), do: List.duplicate(%{}, n)

  defp run(data, []), do: {data, nil}

  defp run(data, [{name, params} | rest]) when name in @image_filters do
    if rest == [], do: {data, {canonical(name), params}}, else: run(data, rest)
  end

  defp run(data, [{name, params} | rest]) do
    run(apply_filter(name, data, params), rest)
  end

  defp canonical("DCT"), do: "DCTDecode"
  defp canonical("CCF"), do: "CCITTFaxDecode"
  defp canonical(name), do: name

  @doc false
  def apply_filter(name, data, params) when name in ["FlateDecode", "Fl"],
    do: data |> inflate() |> predict(params)

  def apply_filter(name, data, params) when name in ["LZWDecode", "LZW"] do
    early = Map.get(params, "EarlyChange", 1)
    data |> lzw(early) |> predict(params)
  end

  def apply_filter(name, data, _) when name in ["ASCIIHexDecode", "AHx"], do: ascii_hex(data)
  def apply_filter(name, data, _) when name in ["ASCII85Decode", "A85"], do: ascii85(data)
  def apply_filter(name, data, _) when name in ["RunLengthDecode", "RL"], do: run_length(data, [])
  def apply_filter("Crypt", data, _), do: data
  def apply_filter(_unknown, data, _), do: data

  # ---------------------------------------------------------------- Flate

  @doc "Inflates zlib (or raw deflate) data, keeping whatever decodes before an error."
  @spec inflate(binary()) :: binary()
  def inflate(<<>>), do: <<>>

  def inflate(data) do
    case safe_inflate(data, :zlib) do
      {:ok, out} -> out
      {:error, partial} when partial != <<>> -> partial
      {:error, _} -> try_raw(data)
    end
  end

  defp try_raw(data) do
    case safe_inflate(data, :raw) do
      {:ok, out} -> out
      {:error, partial} -> partial
    end
  end

  defp safe_inflate(data, mode) do
    z = :zlib.open()

    try do
      case mode do
        :zlib -> :zlib.inflateInit(z)
        :raw -> :zlib.inflateInit(z, -15)
      end

      loop_inflate(z, :zlib.safeInflate(z, data), [])
    rescue
      _ -> {:error, <<>>}
    catch
      _, _ -> {:error, <<>>}
    after
      :zlib.close(z)
    end
  end

  defp loop_inflate(z, {:continue, out}, acc) do
    acc = [acc | out]

    try do
      loop_inflate(z, :zlib.safeInflate(z, []), acc)
    rescue
      _ -> {:error, IO.iodata_to_binary(acc)}
    catch
      _, _ -> {:error, IO.iodata_to_binary(acc)}
    end
  end

  defp loop_inflate(_z, {:finished, out}, acc), do: {:ok, IO.iodata_to_binary([acc | out])}
  defp loop_inflate(_z, {:need_dictionary, _, _}, acc), do: {:error, IO.iodata_to_binary(acc)}

  # ---------------------------------------------------------------- predictors

  @doc false
  def predict(data, params) when is_map(params) do
    predictor = Map.get(params, "Predictor", 1)

    if predictor in [nil, 1] do
      data
    else
      colors = Map.get(params, "Colors", 1)
      bpc = Map.get(params, "BitsPerComponent", 8)
      columns = Map.get(params, "Columns", 1)
      bpp = max(div(colors * bpc + 7, 8), 1)
      row_len = div(colors * bpc * columns + 7, 8)

      cond do
        predictor == 2 -> tiff_predict(data, row_len, bpp, bpc, colors)
        predictor >= 10 -> png_predict(data, row_len, bpp)
        true -> data
      end
    end
  end

  def predict(data, _), do: data

  defp png_predict(data, row_len, bpp) do
    prev = :binary.copy(<<0>>, row_len)
    png_rows(data, row_len, bpp, prev, [])
  end

  defp png_rows(<<type, rest::binary>>, row_len, bpp, prev, acc) do
    {row, rest} =
      if byte_size(rest) >= row_len,
        do:
          {binary_part(rest, 0, row_len), binary_part(rest, row_len, byte_size(rest) - row_len)},
        else: {rest <> :binary.copy(<<0>>, row_len - byte_size(rest)), <<>>}

    decoded = unfilter(type, row, prev, bpp)
    png_rows(rest, row_len, bpp, decoded, [decoded | acc])
  end

  defp png_rows(<<>>, _row_len, _bpp, _prev, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  @doc false
  # PNG row unfiltering; also used by the PNG reader of the image pipeline.
  def unfilter(0, row, _prev, _bpp), do: row

  def unfilter(1, row, _prev, bpp) do
    row |> :binary.bin_to_list() |> sub_filter(bpp) |> :erlang.list_to_binary()
  end

  def unfilter(2, row, prev, _bpp) do
    :binary.bin_to_list(row)
    |> Enum.zip(:binary.bin_to_list(prev))
    |> Enum.map(fn {a, b} -> band(a + b, 0xFF) end)
    |> :erlang.list_to_binary()
  end

  def unfilter(3, row, prev, bpp) do
    cur = :binary.bin_to_list(row)
    up = :binary.bin_to_list(prev)
    average(cur, up, List.duplicate(0, bpp), bpp, []) |> :erlang.list_to_binary()
  end

  def unfilter(4, row, prev, bpp) do
    cur = :binary.bin_to_list(row)
    up = :binary.bin_to_list(prev)
    paeth(cur, up, List.duplicate(0, bpp), List.duplicate(0, bpp), []) |> :erlang.list_to_binary()
  end

  def unfilter(_, row, _prev, _bpp), do: row

  defp sub_filter(bytes, bpp) do
    {out, _} =
      Enum.map_reduce(bytes, :queue.from_list(List.duplicate(0, bpp)), fn b, q ->
        {{:value, left}, q} = :queue.out(q)
        v = band(b + left, 0xFF)
        {v, :queue.in(v, q)}
      end)

    out
  end

  # `lefts` holds the last bpp output bytes (oldest first)
  defp average([], _, _, _, acc), do: Enum.reverse(acc)

  defp average([c | cur], [u | up], [l | lefts], bpp, acc) do
    v = band(c + div(l + u, 2), 0xFF)
    average(cur, up, lefts ++ [v], bpp, [v | acc])
  end

  defp paeth([], _, _, _, acc), do: Enum.reverse(acc)

  defp paeth([c | cur], [u | up], [l | lefts], [ul | uplefts], acc) do
    p = l + u - ul
    pa = abs(p - l)
    pb = abs(p - u)
    pc = abs(p - ul)

    pred =
      cond do
        pa <= pb and pa <= pc -> l
        pb <= pc -> u
        true -> ul
      end

    v = band(c + pred, 0xFF)
    paeth(cur, up, lefts ++ [v], uplefts ++ [u], [v | acc])
  end

  defp tiff_predict(data, row_len, bpp, 8, _colors) do
    for <<row::binary-size(row_len) <- data>>, into: <<>> do
      row |> :binary.bin_to_list() |> sub_filter(bpp) |> :erlang.list_to_binary()
    end
  end

  defp tiff_predict(data, row_len, _bpp, 16, colors) do
    for <<row::binary-size(row_len) <- data>>, into: <<>> do
      samples = for <<s::16 <- row>>, do: s

      {out, _} =
        Enum.map_reduce(samples, :queue.from_list(List.duplicate(0, colors)), fn s, q ->
          {{:value, left}, q} = :queue.out(q)
          v = band(s + left, 0xFFFF)
          {v, :queue.in(v, q)}
        end)

      for v <- out, into: <<>>, do: <<v::16>>
    end
  end

  defp tiff_predict(data, _row_len, _bpp, _bpc, _colors), do: data

  # ---------------------------------------------------------------- LZW

  defp lzw(data, early) do
    lzw_loop(data, 9, 258, %{}, nil, early, [])
  end

  defp lzw_loop(data, width, next, table, prev, early, acc) do
    case data do
      <<code::size(width), rest::bitstring>> ->
        cond do
          code == 256 ->
            lzw_loop(rest, 9, 258, %{}, nil, early, acc)

          code == 257 ->
            acc |> Enum.reverse() |> IO.iodata_to_binary()

          true ->
            entry =
              cond do
                code < 256 -> <<code>>
                Map.has_key?(table, code) -> table[code]
                prev != nil -> prev <> binary_part(prev, 0, 1)
                true -> <<>>
              end

            {table, next} =
              if prev != nil and next < 4096,
                do:
                  {Map.put(table, next, prev <> binary_part(entry, 0, min(1, byte_size(entry)))),
                   next + 1},
                else: {table, next}

            width =
              cond do
                next + early >= 4096 -> 12
                next + early >= 2048 -> 12
                next + early >= 1024 -> 11
                next + early >= 512 -> 10
                true -> 9
              end

            lzw_loop(rest, width, next, table, entry, early, [entry | acc])
        end

      _ ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  # ---------------------------------------------------------------- ASCII

  defp ascii_hex(data) do
    digits =
      for <<c <- data>>, c in ?0..?9 or c in ?a..?f or c in ?A..?F or c == ?>,
        into: <<>>,
        do: <<c>>

    digits =
      case :binary.match(digits, ">") do
        {pos, _} -> binary_part(digits, 0, pos)
        :nomatch -> digits
      end

    digits = if rem(byte_size(digits), 2) == 1, do: digits <> "0", else: digits
    Base.decode16!(digits, case: :mixed)
  end

  defp ascii85(data) do
    data =
      data
      |> then(fn d ->
        if String.starts_with?(d, "<~"), do: binary_part(d, 2, byte_size(d) - 2), else: d
      end)
      |> then(fn d ->
        case :binary.match(d, "~>") do
          {pos, _} -> binary_part(d, 0, pos)
          :nomatch -> d
        end
      end)

    chars = for <<c <- data>>, c not in [0, 9, 10, 12, 13, 32], do: c
    a85(chars, [], [])
  end

  defp a85([], [], out), do: out |> Enum.reverse() |> IO.iodata_to_binary()

  defp a85([], group, out) do
    n = length(group)
    padded = Enum.reverse(group) ++ List.duplicate(?u, 5 - n)
    <<bytes::binary-size(n - 1), _::binary>> = group_value(padded)
    a85([], [], [bytes | out])
  end

  defp a85([?z | rest], [], out), do: a85(rest, [], [<<0, 0, 0, 0>> | out])

  defp a85([c | rest], group, out) when c in ?!..?u do
    group = [c | group]

    if length(group) == 5,
      do: a85(rest, [], [group_value(Enum.reverse(group)) | out]),
      else: a85(rest, group, out)
  end

  defp a85([_ | rest], group, out), do: a85(rest, group, out)

  defp group_value(chars) do
    value = Enum.reduce(chars, 0, fn c, acc -> acc * 85 + (c - 33) end)
    <<band(value, 0xFFFFFFFF)::32>>
  end

  defp run_length(<<128, _::binary>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp run_length(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp run_length(<<len, rest::binary>>, acc) when len < 128 do
    n = min(len + 1, byte_size(rest))
    <<chunk::binary-size(n), rest::binary>> = rest
    run_length(rest, [chunk | acc])
  end

  defp run_length(<<len, byte, rest::binary>>, acc),
    do: run_length(rest, [:binary.copy(<<byte>>, 257 - len) | acc])

  defp run_length(<<_>>, acc), do: run_length(<<>>, acc)

  # ---------------------------------------------------------------- encoding

  @doc "Deflates data (used by the writer)."
  @spec deflate(iodata()) :: binary()
  def deflate(data), do: :zlib.compress(data)
end
