defmodule EmbedPdf.Signatures.Mark do
  @moduledoc """
  Signature marks drawn as appearance streams:

    * `{:text, "Ada Lovelace", opts}` – a typed signature (Times-Italic),
      with an optional date line (`date: true` or `date: DateTime`) and
      `color: {r, g, b}`
    * `{:image, png_or_jpeg_bytes}` – a scanned or drawn signature image,
      fitted into the box keeping its proportions (PNG transparency kept)
    * `{:ink, [[{x, y}]]}` – strokes in box-relative coordinates from 0 to
      1, origin at the top-left (as a drawing UI records them); options
      as `{:ink, strokes, opts}` with `color:` and `width:`
  """

  import Bitwise

  alias EmbedPdf.Edit
  alias EmbedPdf.PDF.{Document, Filter, Stream}

  @ink_color {0.1, 0.16, 0.45}

  @doc """
  Adds the appearance of `mark` sized `{w, h}` to the document and returns
  `{doc, ref}` of the form XObject.
  """
  @spec appearance(Document.t(), term(), {number(), number()}) ::
          {Document.t(), term()} | {:error, term()}
  def appearance(doc, mark, {w, h}) do
    case content(doc, mark, {max(w, 0.0), max(h, 0.0)}) do
      {:ok, doc, content, resources} ->
        Document.add_object(doc, Edit.form({0, 0, w, h}, content, resources))

      {:error, _} = err ->
        err
    end
  end

  defp content(doc, {:text, name}, size), do: content(doc, {:text, name, []}, size)

  defp content(doc, {:text, name, opts}, {w, h}) when is_binary(name) do
    date =
      case opts[:date] do
        true -> Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")
        %DateTime{} = dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
        s when is_binary(s) -> s
        _ -> nil
      end

    {r, g, b} = opts[:color] || @ink_color
    base = "Times-Italic"
    name_band = if date, do: h * 0.68, else: h
    size = fit_size(name, base, w * 0.9, name_band * 0.62)
    name_w = Edit.text_width(name, base, size)
    name_x = (w - name_w) / 2
    name_y = if(date, do: h * 0.32, else: 0) + (name_band - size * 0.72) / 2

    line_y = if date, do: h * 0.3, else: max(name_y - size * 0.18, 1)

    date_ops =
      if date do
        dsize = min(h * 0.16, 9) |> max(4)
        dw = Edit.text_width(date, "Helvetica", dsize)

        [
          "BT /Helv ",
          Edit.f(dsize),
          " Tf 0.35 0.35 0.35 rg ",
          Edit.f((w - dw) / 2),
          " ",
          Edit.f(h * 0.08),
          " Td ",
          Edit.tj(date),
          " ET\n"
        ]
      else
        []
      end

    ops = [
      "q 0.6 0.6 0.6 RG 0.5 w ",
      Edit.f(w * 0.06),
      " ",
      Edit.f(line_y),
      " m ",
      Edit.f(w * 0.94),
      " ",
      Edit.f(line_y),
      " l S Q\n",
      "BT /TiIt ",
      Edit.f(size),
      " Tf ",
      Enum.map_join([r, g, b], " ", &Edit.f/1),
      " rg ",
      Edit.f(name_x),
      " ",
      Edit.f(name_y),
      " Td ",
      Edit.tj(name),
      " ET\n",
      date_ops
    ]

    fonts = %{"TiIt" => Edit.std_font_dict(base), "Helv" => Edit.std_font_dict("Helvetica")}
    {:ok, doc, ops, %{"Font" => fonts}}
  end

  defp content(doc, {:image, bytes}, {w, h}) when is_binary(bytes) do
    case image_object(doc, bytes) do
      {:ok, doc, ref, iw, ih} ->
        scale = min(w * 0.96 / iw, h * 0.96 / ih)
        dw = iw * scale
        dh = ih * scale
        x = (w - dw) / 2
        y = (h - dh) / 2

        ops = [
          "q ",
          Edit.f(dw),
          " 0 0 ",
          Edit.f(dh),
          " ",
          Edit.f(x),
          " ",
          Edit.f(y),
          " cm /Sig Do Q\n"
        ]

        {:ok, doc, ops, %{"XObject" => %{"Sig" => ref}}}

      {:error, _} = err ->
        err
    end
  end

  defp content(doc, {:ink, strokes}, size), do: content(doc, {:ink, strokes, []}, size)

  defp content(doc, {:ink, strokes, opts}, {w, h}) when is_list(strokes) do
    {r, g, b} = opts[:color] || @ink_color
    width = opts[:width] || max(h * 0.035, 0.8)

    paths =
      Enum.map(strokes, fn
        [{x0, y0} | rest] ->
          start = [Edit.f(x0 * w), " ", Edit.f((1 - y0) * h), " m "]

          lines =
            case rest do
              [] ->
                [Edit.f(x0 * w + 0.01), " ", Edit.f((1 - y0) * h), " l "]

              pts ->
                Enum.map(pts, fn {x, y} -> [Edit.f(x * w), " ", Edit.f((1 - y) * h), " l "] end)
            end

          [start, lines, "S\n"]

        _ ->
          []
      end)

    ops = [
      "q 1 J 1 j ",
      Edit.f(width),
      " w ",
      Enum.map_join([r, g, b], " ", &Edit.f/1),
      " RG\n",
      paths,
      "Q\n"
    ]

    {:ok, doc, ops, %{}}
  end

  defp content(_doc, mark, _), do: {:error, {:unsupported_mark, mark}}

  defp fit_size(text, base, max_w, max_h) do
    at_one = Edit.text_width(text, base, 1)
    by_width = if at_one > 0, do: max_w / at_one, else: max_h
    min(by_width, max_h) |> max(4.0)
  end

  # ---------------------------------------------------------------- images

  @doc """
  Adds an image (PNG or JPEG bytes) as an Image XObject: `{:ok, doc, ref,
  width, height}`.
  """
  def image_object(doc, <<0xFF, 0xD8, _::binary>> = jpeg) do
    case jpeg_info(jpeg) do
      {:ok, w, h, comps, adobe?} ->
        cs =
          case comps do
            1 -> "DeviceGray"
            4 -> "DeviceCMYK"
            _ -> "DeviceRGB"
          end

        dict =
          %{
            "Type" => "XObject",
            "Subtype" => "Image",
            "Width" => w,
            "Height" => h,
            "ColorSpace" => cs,
            "BitsPerComponent" => 8,
            "Filter" => "DCTDecode"
          }
          |> then(
            &if(comps == 4 and adobe?,
              do: Map.put(&1, "Decode", [1, 0, 1, 0, 1, 0, 1, 0]),
              else: &1
            )
          )

        {doc, ref} = Document.add_object(doc, %Stream{dict: dict, raw: jpeg})
        {:ok, doc, ref, w, h}

      :error ->
        {:error, :bad_jpeg}
    end
  end

  def image_object(doc, <<0x89, "PNG\r\n", 0x1A, "\n", _::binary>> = png) do
    case decode_png(png) do
      {:ok, w, h, color, alpha} ->
        {doc, smask} =
          if alpha do
            Document.add_object(doc, %Stream{
              dict: %{
                "Type" => "XObject",
                "Subtype" => "Image",
                "Width" => w,
                "Height" => h,
                "ColorSpace" => "DeviceGray",
                "BitsPerComponent" => 8,
                "Filter" => "FlateDecode"
              },
              raw: Filter.deflate(alpha)
            })
          else
            {doc, nil}
          end

        {cs, data} = color

        dict =
          %{
            "Type" => "XObject",
            "Subtype" => "Image",
            "Width" => w,
            "Height" => h,
            "ColorSpace" => cs,
            "BitsPerComponent" => 8,
            "Filter" => "FlateDecode"
          }
          |> then(&if(smask, do: Map.put(&1, "SMask", smask), else: &1))

        {doc, ref} = Document.add_object(doc, %Stream{dict: dict, raw: Filter.deflate(data)})
        {:ok, doc, ref, w, h}

      {:error, _} = err ->
        err
    end
  end

  def image_object(_doc, _), do: {:error, :unsupported_image}

  defp jpeg_info(<<0xFF, 0xD8, rest::binary>>), do: jpeg_segments(rest, false)

  defp jpeg_segments(<<0xFF, 0xFF, rest::binary>>, adobe?),
    do: jpeg_segments(<<0xFF, rest::binary>>, adobe?)

  defp jpeg_segments(<<0xFF, marker, len::16, rest::binary>>, adobe?)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] and byte_size(rest) >= 6 do
    <<_precision, h::16, w::16, comps, _::binary>> = rest
    _ = len
    {:ok, w, h, comps, adobe?}
  end

  defp jpeg_segments(<<0xFF, marker, len::16, rest::binary>>, adobe?)
       when len >= 2 and byte_size(rest) >= len - 2 do
    <<seg::binary-size(len - 2), after_seg::binary>> = rest
    adobe? = adobe? or (marker == 0xEE and String.starts_with?(seg, "Adobe"))
    jpeg_segments(after_seg, adobe?)
  end

  defp jpeg_segments(_, _), do: :error

  @doc """
  Decodes a PNG into `{:ok, width, height, {color_space, bytes}, alpha | nil}`
  with 8-bit samples (non-interlaced, any color type and bit depth).
  """
  def decode_png(<<0x89, "PNG\r\n", 0x1A, "\n", chunks::binary>>) do
    with {:ok, parts} <- png_chunks(chunks, %{idat: []}),
         %{"IHDR" => <<w::32, h::32, depth, color, _comp, _filter, 0>>} <- parts do
      raw = parts.idat |> Enum.reverse() |> IO.iodata_to_binary() |> Filter.inflate()
      channels = %{0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}[color]
      bpp = max(div(channels * depth, 8), 1)
      row_len = div(w * channels * depth + 7, 8)
      rows = unfilter_rows(raw, row_len, bpp)
      samples = Enum.map(rows, &samples(&1, w * channels, depth))
      convert(samples, w, h, color, depth, parts)
    else
      {:error, _} = err -> err
      _ -> {:error, :unsupported_png}
    end
  rescue
    _ -> {:error, :bad_png}
  end

  def decode_png(_), do: {:error, :bad_png}

  defp png_chunks(
         <<len::32, type::binary-4, data::binary-size(len), _crc::32, rest::binary>>,
         acc
       ) do
    case type do
      "IDAT" -> png_chunks(rest, %{acc | idat: [data | acc.idat]})
      "IEND" -> {:ok, acc}
      t -> png_chunks(rest, Map.put(acc, t, data))
    end
  end

  defp png_chunks(_, acc), do: {:ok, acc}

  defp unfilter_rows(raw, row_len, bpp) do
    {rows, _} =
      Enum.map_reduce(
        0..(div(byte_size(raw), row_len + 1) - 1)//1,
        :binary.copy(<<0>>, row_len),
        fn i, prev ->
          <<type, row::binary-size(row_len)>> = binary_part(raw, i * (row_len + 1), row_len + 1)
          out = Filter.unfilter(type, row, prev, bpp)
          {out, out}
        end
      )

    rows
  end

  # a row's samples as a list of 0..255 values
  defp samples(row, count, 8), do: row |> :binary.bin_to_list() |> Enum.take(count)
  defp samples(row, count, 16), do: for(<<v::16 <- row>>, do: v >>> 8) |> Enum.take(count)

  defp samples(row, count, depth) when depth in [1, 2, 4] do
    for(<<v::size(depth) <- row>>, do: v) |> Enum.take(count)
  end

  defp convert(rows, w, h, color, depth, parts) do
    scale = fn v -> if depth < 8, do: div(v * 255, (1 <<< depth) - 1), else: v end
    _ = {w, h}

    case color do
      0 ->
        {:ok, w, h,
         {"DeviceGray", rows |> List.flatten() |> Enum.map(scale) |> :erlang.list_to_binary()},
         nil}

      2 ->
        {:ok, w, h, {"DeviceRGB", rows |> List.flatten() |> :erlang.list_to_binary()}, nil}

      3 ->
        palette = parts["PLTE"] || <<>>
        trns = parts["tRNS"] || <<>>
        idx = List.flatten(rows)

        rgb =
          for i <- idx, into: <<>> do
            if 3 * i + 3 <= byte_size(palette),
              do: binary_part(palette, 3 * i, 3),
              else: <<0, 0, 0>>
          end

        alpha =
          if trns == <<>>,
            do: nil,
            else:
              for(
                i <- idx,
                into: <<>>,
                do: <<if(i < byte_size(trns), do: :binary.at(trns, i), else: 255)>>
              )

        {:ok, w, h, {"DeviceRGB", rgb}, alpha}

      4 ->
        flat = List.flatten(rows)
        {gray, alpha} = split_alpha(flat, 1)
        {:ok, w, h, {"DeviceGray", gray}, alpha}

      6 ->
        flat = List.flatten(rows)
        {rgb, alpha} = split_alpha(flat, 3)
        {:ok, w, h, {"DeviceRGB", rgb}, alpha}

      _ ->
        {:error, :unsupported_png}
    end
  end

  defp split_alpha(values, n) do
    {color, alpha} =
      values
      |> Enum.chunk_every(n + 1)
      |> Enum.reduce({[], []}, fn px, {c, a} ->
        {cs, [al]} = Enum.split(px, n)
        {[cs | c], [al | a]}
      end)

    {color |> Enum.reverse() |> List.flatten() |> :erlang.list_to_binary(),
     alpha |> Enum.reverse() |> :erlang.list_to_binary()}
  end
end
