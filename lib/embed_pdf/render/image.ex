defmodule EmbedPdf.Render.Image do
  @moduledoc """
  Turns PDF images (XObjects and inline images) into something a browser
  can draw: JPEG data passes through untouched, everything else is decoded
  and re-encoded as PNG. Soft masks, stencil masks and color-key masks
  become a separate alpha PNG, used as an SVG `<mask>` (`mask-type: alpha`).

  JPEG 2000 and JBIG2 images are not decoded; `prepare/4` reports them as
  `{:placeholder, kind}`.

  ## Limits

  An image's size comes from its dictionary, not from its data, so it is
  checked before anything is decoded or padded: samples that would take
  more than `:max_image_bytes` (width × height × components × bits / 8;
  default 64 MB) make the image, stencil mask or soft mask a
  `{:placeholder, :too_large}`, and so does an image past the page's share
  (`EmbedPdf.Render.Interpreter.new_budget/0`). JPEG data is passed on as
  it is and has no such limit.

      config :embedpdf_ex, max_image_bytes: 64_000_000
  """

  import Bitwise

  alias EmbedPdf.PDF.{Document, Filter, Stream}
  alias EmbedPdf.Render.{CCITT, ColorSpace, Interpreter, PNG}

  @max_side 4000
  @default_max_bytes 64_000_000
  # filters whose data is not decoded here
  @encoded ~w(DCTDecode DCT JPXDecode JBIG2Decode)
  @slow_weight 8

  @type prepared :: %{
          href: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          mask: {:alpha | :luminance, String.t()} | nil,
          pixelated: boolean()
        }

  @doc """
  Prepares an image for drawing. `fill` is the current fill color, used by
  stencil masks (`/ImageMask true`).
  """
  @spec prepare(Document.t(), term(), map() | nil, {number(), number(), number()}) ::
          {:ok, prepared()} | {:placeholder, atom()} | :skip
  def prepare(doc, image, resources, fill) do
    {dict, raw} = parts(doc, image)
    w = int(dict["Width"])
    h = int(dict["Height"])

    cond do
      w <= 0 or h <= 0 ->
        :skip

      dict["ImageMask"] == true ->
        stencil(doc, dict, raw, w, h, fill)

      true ->
        color_image(doc, dict, raw, w, h, resources)
    end
  rescue
    _ -> :skip
  catch
    :too_large -> {:placeholder, :too_large}
  end

  defp max_bytes do
    case Application.get_env(:embedpdf_ex, :max_image_bytes, @default_max_bytes) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_bytes
    end
  end

  # Lets `bytes` of samples (at most `limit`) into memory, or gives the
  # image up.
  defp admit(bytes, limit \\ max_bytes()) do
    if bytes > limit or not Interpreter.charge_image(bytes), do: throw(:too_large), else: :ok
  end

  defp encoded?(dict), do: Enum.any?(List.wrap(dict["Filter"]), &(&1 in @encoded))

  defp parts(doc, %Stream{dict: dict, raw: raw}), do: {resolve_dict(doc, dict), raw}
  defp parts(doc, %{dict: dict, data: data}), do: {resolve_dict(doc, dict), data}

  defp resolve_dict(doc, dict) do
    Map.new(dict, fn {k, v} ->
      v = Document.resolve(doc, v)

      v =
        if is_list(v) and k in ["Filter", "DecodeParms", "Decode", "Mask"],
          do: Enum.map(v, &Document.resolve(doc, &1)),
          else: v

      {k, v}
    end)
  end

  defp int(v) when is_integer(v), do: v
  defp int(v) when is_float(v), do: trunc(v)
  defp int(_), do: 0

  # ---------------------------------------------------------------- decoding

  defp decode_data(dict, raw) do
    filters = dict["Filter"]
    params = dict["DecodeParms"] || dict["DP"]

    case Filter.decode(raw, filters, params) do
      {data, nil} -> {:raw, data}
      {data, {"DCTDecode", _}} -> {:jpeg, data}
      {_data, {"JPXDecode", _}} -> {:placeholder, :jpx}
      {_data, {"JBIG2Decode", _}} -> {:placeholder, :jbig2}
      {data, {"CCITTFaxDecode", p}} -> ccitt(data, p, dict)
      {data, _} -> {:raw, data}
    end
  end

  defp ccitt(data, params, dict) do
    params = if is_map(params), do: params, else: %{}

    case CCITT.decode(data, params, int(dict["Width"]), int(dict["Height"]), max_bytes()) do
      {:ok, bits} -> {:raw, bits}
      :error -> {:placeholder, :ccitt}
    end
  end

  # ---------------------------------------------------------------- stencil masks

  defp stencil(_doc, dict, raw, w, h, {r, g, b}) do
    admit(div(w + 7, 8) * h)

    case decode_data(dict, raw) do
      {:raw, data} ->
        paint = {round(r * 255), round(g * 255), round(b * 255)}
        inverted? = match?([1 | _], dict["Decode"]) or match?([1.0 | _], dict["Decode"])
        # sample 0 paints (Decode [0 1]); palette index 0 → paint color
        trns = if inverted?, do: [0, 255], else: [255, 0]
        png = PNG.encode(w, h, :palette, 1, data, palette: [paint, {0, 0, 0}], transparency: trns)
        {:ok, %{href: PNG.data_uri(png), width: w, height: h, mask: nil, pixelated: true}}

      {:jpeg, _} ->
        :skip

      other ->
        other
    end
  end

  # ---------------------------------------------------------------- color images

  defp color_image(doc, dict, raw, w, h, resources) do
    cs = image_color_space(doc, dict, resources)
    bpc = int(dict["BitsPerComponent"] || 8)
    bpc = if bpc in [1, 2, 4, 8, 16], do: bpc, else: 8
    # CCITT data is 1-bit regardless of what the dictionary claims
    {cs, bpc} = if ccitt?(dict), do: {:gray, 1}, else: {cs, bpc}
    bytes = div(w * ColorSpace.components(cs) * bpc + 7, 8) * h
    encoded? = encoded?(dict)
    if not encoded?, do: admit(bytes)

    case decode_data(dict, raw) do
      {:jpeg, data} ->
        mask = mask_for(doc, dict, w, h, nil, cs, bpc)

        {:ok,
         %{
           href: "data:image/jpeg;base64," <> Base.encode64(data),
           width: w,
           height: h,
           mask: mask,
           pixelated: false
         }}

      {:raw, data} ->
        if encoded?, do: admit(bytes)
        {png, color_key_mask} = to_png(dict, data, w, h, cs, bpc)
        mask = color_key_mask || mask_for(doc, dict, w, h, data, cs, bpc)

        {:ok,
         %{
           href: PNG.data_uri(png),
           width: w,
           height: h,
           mask: mask,
           pixelated: bpc == 1 and w * h < 1_000_000
         }}

      other ->
        other
    end
  end

  defp ccitt?(dict),
    do: "CCITTFaxDecode" in List.wrap(dict["Filter"]) or "CCF" in List.wrap(dict["Filter"])

  defp image_color_space(doc, dict, resources) do
    case dict["ColorSpace"] do
      nil -> :gray
      cs -> ColorSpace.parse(doc, cs, resources)
    end
  end

  defp decode_array(dict) do
    case dict["Decode"] do
      list when is_list(list) -> Enum.map(list, &((&1 || 0) / 1))
      _ -> nil
    end
  end

  defp default_decode?(nil, _cs, _bpc), do: true

  defp default_decode?(decode, cs, bpc) do
    defaults = cs |> ColorSpace.default_decode(bpc) |> Enum.map(&(&1 / 1))
    Enum.zip(decode, defaults) |> Enum.all?(fn {a, b} -> abs(a - b) < 1.0e-6 end)
  end

  defp inverted_single?([1.0, +0.0]), do: true
  defp inverted_single?([1.0, -0.0]), do: true
  defp inverted_single?(_), do: false

  # returns {png, nil | color_key_mask_href}
  defp to_png(dict, data, w, h, cs, bpc) do
    decode = decode_array(dict)
    default? = default_decode?(decode, cs, bpc)
    n = ColorSpace.components(cs)
    row = div(w * n * bpc + 7, 8)
    data = fit(data, row * h)
    # shrink huge 8-bit images before any per-pixel work
    {data, w, h} = if bpc == 8, do: shrink(data, w, h, n), else: {data, w, h}

    case {cs, default?} do
      {:gray, true} ->
        {downsample_png(w, h, :gray, bpc, data), nil}

      {:gray, false} ->
        if inverted_single?(decode),
          do: {downsample_png(w, h, :gray, bpc, invert(data)), nil},
          else: {generic(dict, data, w, h, cs, bpc, decode), nil}

      {:rgb, true} when bpc in [8, 16] ->
        {downsample_png(w, h, :rgb, bpc, data), nil}

      {{:indexed, base, hival, lookup}, true} when bpc in [1, 2, 4, 8] ->
        palette =
          for i <- 0..min(hival, 255)//1 do
            {r, g, b} = ColorSpace.to_rgb({:indexed, base, hival, lookup}, [i])
            {round(r * 255), round(g * 255), round(b * 255)}
          end

        size = min(1 <<< bpc, 256)
        palette = palette ++ List.duplicate({0, 0, 0}, max(size - length(palette), 0))
        palette = Enum.take(palette, size)

        trns = indexed_color_key(dict["Mask"], size)
        opts = [palette: palette] ++ if(trns, do: [transparency: trns], else: [])
        {PNG.encode(w, h, :palette, bpc, data, opts), nil}

      {:cmyk, true} when bpc == 8 ->
        rgb =
          for <<c, m, y, k <- data>>, into: <<>> do
            ik = 255 - k
            <<div((255 - c) * ik, 255), div((255 - m) * ik, 255), div((255 - y) * ik, 255)>>
          end

        {downsample_png(w, h, :rgb, 8, rgb), nil}

      _ ->
        {generic(dict, data, w, h, cs, bpc, decode), nil}
    end
  end

  defp invert(data), do: for(<<b <- data>>, into: <<>>, do: <<bnot(b) &&& 0xFF>>)

  defp fit(data, size) when byte_size(data) >= size, do: binary_part(data, 0, size)
  defp fit(data, size), do: data <> :binary.copy(<<0>>, size - byte_size(data))

  defp indexed_color_key([lo, hi | _], size) when is_number(lo) and is_number(hi) do
    for i <- 0..(size - 1), do: if(i >= lo and i <= hi, do: 0, else: 255)
  end

  defp indexed_color_key(_, _), do: nil

  # Generic conversion through ColorSpace.to_rgb with Decode support.
  defp generic(_dict, data, w, h, cs, bpc, decode) do
    n = ColorSpace.components(cs)
    max = (1 <<< bpc) - 1
    decode = decode || ColorSpace.default_decode(cs, bpc)

    ranges =
      for i <- 0..(n - 1) do
        {Enum.at(decode, 2 * i, 0) / 1, Enum.at(decode, 2 * i + 1, 1) / 1}
      end

    to_value = fn i, s ->
      {d0, d1} = Enum.at(ranges, i)
      d0 + s * (d1 - d0) / max
    end

    rgb_bytes = fn comps ->
      {r, g, b} = ColorSpace.to_rgb(cs, comps)
      <<round(r * 255), round(g * 255), round(b * 255)>>
    end

    row_bytes = div(w * n * bpc + 7, 8)
    # every pixel becomes three bytes, however few bits it had
    admit(w * h * 3, 4 * max_bytes())

    convert = fn px ->
      px |> Enum.with_index() |> Enum.map(fn {s, i} -> to_value.(i, s) end) |> rgb_bytes.()
    end

    out =
      cond do
        n == 1 and bpc <= 8 ->
          table = for(s <- 0..max, do: rgb_bytes.([to_value.(0, s)])) |> List.to_tuple()
          lookup(data, w, bpc, row_bytes, table)

        bpc >= 8 ->
          # every pixel may need converting, which is slow: such images get a
          # smaller part of the page's share
          if not Interpreter.charge_image(w * h * 3 * @slow_weight), do: throw(:too_large)
          # whole bytes: pixels are taken straight from the data
          convert_bytes(data, n * div(bpc, 8), bpc, convert, %{}, <<>>)

        w * h > @max_side * @max_side ->
          throw(:too_large)

        true ->
          {out, _cache} =
            for <<row::binary-size(row_bytes) <- data>>, reduce: {[], %{}} do
              {acc, cache} ->
                samples = row_samples(row, w * n, bpc)

                {pixels, cache} =
                  samples
                  |> Enum.chunk_every(n)
                  |> Enum.map_reduce(cache, fn px, cache ->
                    case Map.fetch(cache, px) do
                      {:ok, v} ->
                        {v, cache}

                      :error ->
                        v = convert.(px)

                        cache =
                          if map_size(cache) < 65_536, do: Map.put(cache, px, v), else: cache

                        {v, cache}
                    end
                  end)

                {[acc | IO.iodata_to_binary(pixels)], cache}
            end

          IO.iodata_to_binary(out)
      end

    downsample_png(w, h, :rgb, 8, out)
  end

  # one component of 8 bits or fewer: `table` has the color of every sample
  defp lookup(data, _w, 8, _row_bytes, table),
    do: for(<<s <- data>>, into: <<>>, do: elem(table, s))

  defp lookup(data, w, bpc, row_bytes, table) do
    # the colors of the pixels in a byte, for every byte
    bytes =
      for b <- 0..255 do
        byte = <<b>>
        for <<s::size(bpc) <- byte>>, into: <<>>, do: elem(table, s)
      end
      |> List.to_tuple()

    for <<row::binary-size(row_bytes) <- data>>, into: <<>> do
      colors = for <<b <- row>>, into: <<>>, do: elem(bytes, b)
      binary_part(colors, 0, w * 3)
    end
  end

  # Pixels of `size` whole bytes; the colors of the first 65536 different
  # ones are remembered.
  defp convert_bytes(data, size, bpc, convert, cache, out) do
    case data do
      <<px::binary-size(size), rest::binary>> ->
        case cache do
          %{^px => v} ->
            convert_bytes(rest, size, bpc, convert, cache, <<out::binary, v::binary>>)

          _ ->
            v = convert.(for <<s::size(bpc) <- px>>, do: s)
            cache = if map_size(cache) < 65_536, do: Map.put(cache, px, v), else: cache
            convert_bytes(rest, size, bpc, convert, cache, <<out::binary, v::binary>>)
        end

      _ ->
        out
    end
  end

  defp row_samples(row, count, bpc) do
    samples = for <<s::size(bpc) <- row>>, do: s
    Enum.take(samples, count)
  end

  # ---------------------------------------------------------------- downsampling

  defp shrink(data, w, h, ch) do
    k = div(max(w, h) + @max_side - 1, @max_side)

    if k > 1 do
      row = w * ch
      nw = max(div(w, k), 1)
      nh = max(div(h, k), 1)

      rows =
        for y <- 0..(nh - 1)//1 do
          line = binary_part(data, y * k * row, row)
          for x <- 0..(nw - 1)//1, into: <<>>, do: binary_part(line, x * k * ch, ch)
        end

      {IO.iodata_to_binary(rows), nw, nh}
    else
      {data, w, h}
    end
  end

  defp downsample_png(w, h, color, bpc, data) do
    k = div(max(w, h) + @max_side - 1, @max_side)

    if k > 1 and bpc == 8 do
      ch = PNG.channels(color)
      row = w * ch
      nw = div(w, k)
      nh = div(h, k)

      rows =
        for y <- 0..(nh - 1)//1 do
          line = binary_part(data, y * k * row, row)
          for x <- 0..(nw - 1)//1, into: <<>>, do: binary_part(line, x * k * ch, ch)
        end

      PNG.encode(max(nw, 1), max(nh, 1), color, 8, rows)
    else
      PNG.encode(w, h, color, bpc, data)
    end
  end

  # ---------------------------------------------------------------- masks

  # alpha mask PNG (palette with tRNS ramp), from /SMask, /Mask stream or /Mask array
  defp mask_for(doc, dict, w, h, data, cs, bpc) do
    cond do
      match?(%Stream{}, dict["SMask"]) ->
        soft_mask(doc, dict["SMask"])

      match?(%Stream{}, dict["Mask"]) ->
        explicit_mask(doc, dict["Mask"])

      is_list(dict["Mask"]) and data != nil ->
        color_key(dict["Mask"], data, w, h, cs, bpc)

      true ->
        nil
    end
  end

  defp soft_mask(doc, %Stream{} = s) do
    {dict, raw} = parts(doc, s)
    w = int(dict["Width"])
    h = int(dict["Height"])
    bpc = int(dict["BitsPerComponent"] || 8)
    bpc = if bpc in [1, 2, 4, 8, 16], do: bpc, else: 8
    if not encoded?(dict), do: admit(div(w * bpc + 7, 8) * max(h, 0))

    case decode_data(dict, raw) do
      {:raw, data} when w > 0 and h > 0 ->
        {data, bpc} =
          if bpc == 16,
            do: {for(<<v::16 <- data>>, into: <<>>, do: <<v >>> 8>>), 8},
            else: {data, bpc}

        max = (1 <<< bpc) - 1
        {d0, d1} = mask_decode(dict)

        alphas =
          for s <- 0..max, do: round((d0 + s * (d1 - d0) / max) * 255) |> max(0) |> min(255)

        palette = List.duplicate({0, 0, 0}, max + 1)

        png =
          PNG.encode(w, h, :palette, bpc, fit(data, div(w * bpc + 7, 8) * h),
            palette: palette,
            transparency: alphas
          )

        {:alpha, PNG.data_uri(png)}

      {:jpeg, data} ->
        # a JPEG soft mask is gray levels: use it as a luminance mask
        {:luminance, "data:image/jpeg;base64," <> Base.encode64(data)}

      _ ->
        nil
    end
  end

  defp mask_decode(dict) do
    case dict["Decode"] do
      [a, b | _] when is_number(a) and is_number(b) -> {a / 1, b / 1}
      _ -> {0.0, 1.0}
    end
  end

  defp explicit_mask(doc, %Stream{} = s) do
    {dict, raw} = parts(doc, s)
    w = int(dict["Width"])
    h = int(dict["Height"])
    admit(div(w + 7, 8) * max(h, 0))

    case decode_data(dict, raw) do
      {:raw, data} when w > 0 and h > 0 ->
        # sample 1 is masked out with the default Decode [0 1]
        inverted? = match?({1.0, _}, mask_decode(dict))
        alphas = if inverted?, do: [0, 255], else: [255, 0]

        png =
          PNG.encode(w, h, :palette, 1, fit(data, div(w + 7, 8) * h),
            palette: [{0, 0, 0}, {0, 0, 0}],
            transparency: alphas
          )

        {:alpha, PNG.data_uri(png)}

      _ ->
        nil
    end
  end

  defp color_key(ranges, data, w, h, cs, bpc) when bpc == 8 do
    n = ColorSpace.components(cs)

    pairs =
      ranges
      |> Enum.chunk_every(2)
      |> Enum.map(fn
        [a, b] -> {a, b}
        [a] -> {a, a}
      end)

    if length(pairs) == n and match?({:indexed, _, _, _}, cs) == false do
      alpha =
        for <<px::binary-size(n) <- fit(data, w * n * h)>>, into: <<>> do
          comps = :binary.bin_to_list(px)

          masked? =
            Enum.zip(comps, pairs) |> Enum.all?(fn {c, {lo, hi}} -> c >= lo and c <= hi end)

          if masked?, do: <<0>>, else: <<1>>
        end

      png =
        PNG.encode(w, h, :palette, 8, alpha,
          palette: [{0, 0, 0}, {0, 0, 0}],
          transparency: [0, 255]
        )

      {:alpha, PNG.data_uri(png)}
    end
  end

  defp color_key(_, _, _, _, _, _), do: nil
end
