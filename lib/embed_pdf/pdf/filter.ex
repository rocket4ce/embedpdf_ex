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

  # a longer chain is not a real stream, it is a decompression bomb
  @max_filters 8

  # Predictor rows: what real images and cross-reference streams stay within.
  # A row is unfiltered as lists, a hundred times its size, so rows are far
  # smaller than streams: 2 MB is 250 000 pixels of 16-bit CMYK across.
  @max_columns 1_000_000
  @max_row_bytes 2_000_000

  @doc """
  The largest decoded size of one stream, in bytes: `config :embedpdf_ex,
  max_stream_bytes: 256_000_000`. A stream that would decode to more comes
  back empty.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes do
    case Application.get_env(:embedpdf_ex, :max_stream_bytes, 256_000_000) do
      n when is_integer(n) and n > 0 -> n
      _ -> 256_000_000
    end
  end

  @doc """
  Decodes `data` through `filters` (a name or list of names) with their
  `params` (a dict, a list of dicts or nil).

  Returns `{decoded, nil}` when fully decoded, or `{partially_decoded,
  {image_filter, params}}` when an image filter remains. A stream that
  decodes to more than `max_bytes/0` at any step of the chain, or that has
  more than #{@max_filters} filters, decodes to `{"", nil}`.
  """
  @spec decode(binary(), term(), term()) :: {binary(), nil | {binary(), map()}}
  def decode(data, filters, params) do
    case decode_within(data, filters, params, max_bytes()) do
      {:ok, result} -> result
      :too_large -> {<<>>, nil}
    end
  end

  @doc "Decodes completely, leaving image-codec data as is."
  @spec decode!(binary(), term(), term()) :: binary()
  def decode!(data, filters, params), do: data |> decode(filters, params) |> elem(0)

  @doc """
  `decode/3` with an explicit size limit, telling a stream that went over it
  (`:too_large`) from one that decoded.
  """
  @spec decode_within(binary(), term(), term(), integer()) ::
          {:ok, {binary(), nil | {binary(), map()}}} | :too_large
  def decode_within(data, filters, params, max) do
    filters = List.wrap(filters)
    count = length(filters)

    if count > @max_filters or max <= 0 do
      :too_large
    else
      params = normalize_params(params, count)

      try do
        {:ok, run(data, Enum.zip(filters, params), max)}
      catch
        :throw, :embedpdf_stream_too_large -> :too_large
      end
    end
  end

  defp normalize_params(nil, n), do: List.duplicate(%{}, n)
  defp normalize_params(p, n) when is_map(p), do: [p | List.duplicate(%{}, max(n - 1, 0))]

  defp normalize_params(list, n) when is_list(list),
    do:
      Enum.map(list, &if(is_map(&1), do: &1, else: %{})) ++
        List.duplicate(%{}, max(n - length(list), 0))

  defp normalize_params(_, n), do: List.duplicate(%{}, n)

  defp run(data, [], _max), do: {data, nil}

  defp run(data, [{name, params} | rest], max) when name in @image_filters do
    if rest == [], do: {data, {canonical(name), params}}, else: run(data, rest, max)
  end

  defp run(data, [{name, params} | rest], max) do
    run(filter(name, data, params, max), rest, max)
  end

  defp canonical("DCT"), do: "DCTDecode"
  defp canonical("CCF"), do: "CCITTFaxDecode"
  defp canonical(name), do: name

  @doc false
  def apply_filter(name, data, params) do
    filter(name, data, params, max_bytes())
  catch
    :throw, :embedpdf_stream_too_large -> <<>>
  end

  # every filter throws :embedpdf_stream_too_large once its output passes `max`
  defp filter(name, data, params, max) when name in ["FlateDecode", "Fl"],
    do: data |> inflate(max) |> predict(params)

  defp filter(name, data, params, max) when name in ["LZWDecode", "LZW"] do
    early = if Map.get(params, "EarlyChange", 1) == 0, do: 0, else: 1
    data |> lzw(early, max) |> predict(params)
  end

  defp filter(name, data, _, max) when name in ["ASCIIHexDecode", "AHx"],
    do: data |> ascii_hex() |> within(max)

  defp filter(name, data, _, max) when name in ["ASCII85Decode", "A85"], do: ascii85(data, max)

  defp filter(name, data, _, max) when name in ["RunLengthDecode", "RL"],
    do: run_length(data, <<>>, max)

  defp filter(_crypt_or_unknown, data, _, _max), do: data

  defp within(data, max) when byte_size(data) <= max, do: data
  defp within(_data, _max), do: too_large()

  defp too_large, do: throw(:embedpdf_stream_too_large)

  # ---------------------------------------------------------------- Flate

  @doc """
  Inflates zlib (or raw deflate) data, keeping whatever decodes before an
  error. Data that inflates to more than `max_bytes/0` comes back empty.
  """
  @spec inflate(binary()) :: binary()
  def inflate(data) do
    inflate(data, max_bytes())
  catch
    :throw, :embedpdf_stream_too_large -> <<>>
  end

  defp inflate(<<>>, _max), do: <<>>

  defp inflate(data, max) do
    case safe_inflate(data, :zlib, max) do
      {:ok, out} -> out
      {:error, partial} when partial != <<>> -> partial
      {:error, _} -> try_raw(data, max)
      :too_large -> too_large()
    end
  end

  defp try_raw(data, max) do
    case safe_inflate(data, :raw, max) do
      {:ok, out} -> out
      {:error, partial} -> partial
      :too_large -> too_large()
    end
  end

  defp safe_inflate(data, mode, max) do
    z = :zlib.open()

    try do
      case mode do
        :zlib -> :zlib.inflateInit(z)
        :raw -> :zlib.inflateInit(z, -15)
      end

      loop_inflate(z, :zlib.safeInflate(z, data), [], 0, max)
    rescue
      _ -> {:error, <<>>}
    catch
      _, _ -> {:error, <<>>}
    after
      :zlib.close(z)
    end
  end

  defp loop_inflate(z, {:continue, out}, acc, size, max) do
    size = size + IO.iodata_length(out)
    acc = [acc | out]

    if size > max do
      :too_large
    else
      case inflate_more(z) do
        {:ok, step} -> loop_inflate(z, step, acc, size, max)
        :error -> {:error, IO.iodata_to_binary(acc)}
      end
    end
  end

  defp loop_inflate(_z, {:finished, out}, acc, size, max) do
    if size + IO.iodata_length(out) > max,
      do: :too_large,
      else: {:ok, IO.iodata_to_binary([acc | out])}
  end

  defp loop_inflate(_z, {:need_dictionary, _, _}, acc, _size, _max),
    do: {:error, IO.iodata_to_binary(acc)}

  defp inflate_more(z) do
    {:ok, :zlib.safeInflate(z, [])}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # ---------------------------------------------------------------- predictors

  @doc false
  # Parameters that do not describe rows that fit in the data (zero or absurd
  # columns, colours or bit depths) leave the data as it is.
  def predict(data, params) when is_map(params) do
    predictor = Map.get(params, "Predictor", 1)
    colors = Map.get(params, "Colors", 1)
    bpc = Map.get(params, "BitsPerComponent", 8)
    columns = Map.get(params, "Columns", 1)

    if is_integer(predictor) and predictor > 1 and colors in 1..32 and bpc in [1, 2, 4, 8, 16] and
         columns in 1..@max_columns do
      bpp = max(div(colors * bpc + 7, 8), 1)
      row_len = div(colors * bpc * columns + 7, 8)

      cond do
        row_len > byte_size(data) or row_len > @max_row_bytes -> data
        predictor == 2 -> tiff_predict(data, row_len, bpp, bpc, colors)
        predictor >= 10 -> png_predict(data, row_len, bpp)
        true -> data
      end
    else
      data
    end
  end

  def predict(data, _), do: data

  defp png_predict(data, row_len, bpp) do
    prev = :binary.copy(<<0>>, row_len)
    png_rows(data, row_len, bpp, prev, <<>>)
  end

  defp png_rows(<<type, rest::binary>>, row_len, bpp, prev, acc) do
    {row, rest} =
      if byte_size(rest) >= row_len,
        do:
          {binary_part(rest, 0, row_len), binary_part(rest, row_len, byte_size(rest) - row_len)},
        else: {rest <> :binary.copy(<<0>>, row_len - byte_size(rest)), <<>>}

    decoded = unfilter(type, row, prev, bpp)
    png_rows(rest, row_len, bpp, decoded, <<acc::binary, decoded::binary>>)
  end

  defp png_rows(<<>>, _row_len, _bpp, _prev, acc), do: acc

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
    average(cur, up, List.duplicate(0, bpp), [], []) |> :erlang.list_to_binary()
  end

  def unfilter(4, row, prev, bpp) do
    cur = :binary.bin_to_list(row)
    up = :binary.bin_to_list(prev)
    zeros = List.duplicate(0, bpp)
    paeth(cur, up, zeros, [], zeros, [], []) |> :erlang.list_to_binary()
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

  # The last bpp output bytes are a queue: `lefts` is its front (oldest
  # first), `back` what was added since, newest first.
  defp average([], _, _, _, acc), do: Enum.reverse(acc)

  defp average(cur, up, [], back, acc), do: average(cur, up, Enum.reverse(back), [], acc)

  defp average([c | cur], [u | up], [l | lefts], back, acc) do
    v = band(c + div(l + u, 2), 0xFF)
    average(cur, up, lefts, [v | back], [v | acc])
  end

  defp paeth([], _, _, _, _, _, acc), do: Enum.reverse(acc)

  defp paeth(cur, up, [], back, uplefts, upback, acc),
    do: paeth(cur, up, Enum.reverse(back), [], uplefts, upback, acc)

  defp paeth(cur, up, lefts, back, [], upback, acc),
    do: paeth(cur, up, lefts, back, Enum.reverse(upback), [], acc)

  defp paeth([c | cur], [u | up], [l | lefts], back, [ul | uplefts], upback, acc) do
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
    paeth(cur, up, lefts, [v | back], uplefts, [u | upback], [v | acc])
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

  defp lzw(data, early, max) do
    lzw_loop(data, 9, 258, %{}, nil, early, <<>>, max)
  end

  defp lzw_loop(_data, _width, _next, _table, _prev, _early, acc, max)
       when byte_size(acc) > max,
       do: too_large()

  defp lzw_loop(data, width, next, table, prev, early, acc, max) do
    case data do
      <<code::size(width), rest::bitstring>> ->
        cond do
          code == 256 ->
            lzw_loop(rest, 9, 258, %{}, nil, early, acc, max)

          code == 257 ->
            acc

          true ->
            entry =
              cond do
                code < 256 -> <<code>>
                Map.has_key?(table, code) -> table[code]
                # a code that names nothing, with no string before it to extend
                prev in [nil, <<>>] -> <<>>
                true -> prev <> binary_part(prev, 0, 1)
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

            lzw_loop(rest, width, next, table, entry, early, <<acc::binary, entry::binary>>, max)
        end

      _ ->
        acc
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

  defp ascii85(data, max) do
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

    a85(data, 0, 0, <<>>, max)
  end

  # `value` holds the `n` characters of the group being read
  defp a85(_data, _value, _n, out, max) when byte_size(out) > max, do: too_large()

  defp a85(<<>>, _value, 0, out, _max), do: out

  defp a85(<<>>, value, n, out, _max) do
    # a short last group is padded with `u` and gives n - 1 bytes
    padded = Enum.reduce(1..(5 - n), value, fn _, acc -> acc * 85 + (?u - 33) end)
    <<bytes::binary-size(n - 1), _::binary>> = <<band(padded, 0xFFFFFFFF)::32>>
    <<out::binary, bytes::binary>>
  end

  defp a85(<<?z, rest::binary>>, _value, 0, out, max),
    do: a85(rest, 0, 0, <<out::binary, 0, 0, 0, 0>>, max)

  defp a85(<<c, rest::binary>>, value, 4, out, max) when c in ?!..?u do
    value = value * 85 + (c - 33)
    a85(rest, 0, 0, <<out::binary, band(value, 0xFFFFFFFF)::32>>, max)
  end

  defp a85(<<c, rest::binary>>, value, n, out, max) when c in ?!..?u,
    do: a85(rest, value * 85 + (c - 33), n + 1, out, max)

  # whitespace and anything that is not part of the encoding
  defp a85(<<_, rest::binary>>, value, n, out, max), do: a85(rest, value, n, out, max)

  defp run_length(_data, acc, max) when byte_size(acc) > max, do: too_large()
  defp run_length(<<128, _::binary>>, acc, _max), do: acc
  defp run_length(<<>>, acc, _max), do: acc

  defp run_length(<<len, rest::binary>>, acc, max) when len < 128 do
    n = min(len + 1, byte_size(rest))
    <<chunk::binary-size(n), rest::binary>> = rest
    run_length(rest, <<acc::binary, chunk::binary>>, max)
  end

  defp run_length(<<len, byte, rest::binary>>, acc, max),
    do: run_length(rest, <<acc::binary, :binary.copy(<<byte>>, 257 - len)::binary>>, max)

  defp run_length(<<_>>, acc, max), do: run_length(<<>>, acc, max)

  # ---------------------------------------------------------------- encoding

  @doc "Deflates data (used by the writer)."
  @spec deflate(iodata()) :: binary()
  def deflate(data), do: :zlib.compress(data)
end
