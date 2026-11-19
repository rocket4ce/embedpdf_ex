defmodule EmbedPdf.Render.PNG do
  @moduledoc """
  A small PNG encoder (ISO/IEC 15948) built on `:zlib` and `:erlang.crc32/1`.

  Rows are given unfiltered and packed (no filter bytes); every row is
  written with filter type 0, which keeps encoding fast in Elixir.
  """

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @type color_type :: :gray | :rgb | :palette | :gray_alpha | :rgba

  @doc """
  Encodes an image.

    * `color_type` – `:gray`, `:rgb`, `:palette`, `:gray_alpha` or `:rgba`
    * `bit_depth` – 1, 2, 4, 8 or 16 (as PNG allows for the color type)
    * `data` – packed rows, `row_bytes(width, color_type, bit_depth)` each

  Options: `:palette` (list of `{r, g, b}` bytes) and `:transparency`
  (list of alpha bytes for palette entries, or a gray/rgb key value).
  """
  @spec encode(
          pos_integer(),
          pos_integer(),
          color_type(),
          1 | 2 | 4 | 8 | 16,
          iodata(),
          keyword()
        ) ::
          binary()
  def encode(width, height, color_type, bit_depth, data, opts \\ []) do
    data = IO.iodata_to_binary(data)
    row = row_bytes(width, color_type, bit_depth)
    data = fit(data, row * height)

    raw = for <<r::binary-size(row) <- data>>, do: [0, r]

    # big images: favor speed over a few percent of size
    level = Keyword.get(opts, :level, if(byte_size(data) > 4_000_000, do: 1, else: 6))
    idat = compress(raw, level)

    ihdr =
      <<width::32, height::32, bit_depth, color_code(color_type), 0, 0, 0>>

    plte =
      case Keyword.get(opts, :palette) do
        nil -> []
        pal -> chunk("PLTE", for({r, g, b} <- pal, into: <<>>, do: <<r, g, b>>))
      end

    trns =
      case Keyword.get(opts, :transparency) do
        nil -> []
        alphas when is_list(alphas) -> chunk("tRNS", :erlang.list_to_binary(alphas))
        key when is_binary(key) -> chunk("tRNS", key)
      end

    IO.iodata_to_binary([
      @signature,
      chunk("IHDR", ihdr),
      plte,
      trns,
      chunk("IDAT", idat),
      chunk("IEND", <<>>)
    ])
  end

  @doc "Bytes per packed row."
  @spec row_bytes(pos_integer(), color_type(), pos_integer()) :: pos_integer()
  def row_bytes(width, color_type, bit_depth),
    do: div(width * channels(color_type) * bit_depth + 7, 8)

  @doc "Number of samples per pixel."
  def channels(:gray), do: 1
  def channels(:palette), do: 1
  def channels(:gray_alpha), do: 2
  def channels(:rgb), do: 3
  def channels(:rgba), do: 4

  defp color_code(:gray), do: 0
  defp color_code(:rgb), do: 2
  defp color_code(:palette), do: 3
  defp color_code(:gray_alpha), do: 4
  defp color_code(:rgba), do: 6

  defp fit(data, size) when byte_size(data) == size, do: data
  defp fit(data, size) when byte_size(data) > size, do: binary_part(data, 0, size)
  defp fit(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))

  defp compress(iodata, level) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, level)
      out = :zlib.deflate(z, iodata, :finish)
      :zlib.deflateEnd(z)
      IO.iodata_to_binary(out)
    after
      :zlib.close(z)
    end
  end

  defp chunk(type, data) do
    crc = :erlang.crc32([type, data])
    [<<byte_size(data)::32>>, type, data, <<crc::32>>]
  end

  @doc "A `data:` URI for PNG bytes."
  @spec data_uri(binary()) :: String.t()
  def data_uri(png), do: "data:image/png;base64," <> Base.encode64(png)
end
