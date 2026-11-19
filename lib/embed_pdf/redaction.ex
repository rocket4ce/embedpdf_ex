defmodule EmbedPdf.Redaction do
  @moduledoc """
  True redaction: content under the given areas is removed from the file,
  not just covered.

  For every area, `apply/4`:

    * removes the glyphs whose box overlaps it from the page's content
      streams (and from form XObjects, which are copied), keeping the
      remaining glyphs at their positions with `TJ` kerning;
    * paints the area with the fill color in decodable images (re-encoded),
      and drops images it cannot decode (JPEG, JPEG 2000, JBIG2, CCITT,
      stencil masks) and inline images that overlap;
    * drops vector paths lying entirely inside the area;
    * strips `/ActualText` and `/Alt` from marked content that lost text;
    * deletes annotations overlapping the area;
    * paints the area (and optional overlay text).

  Redaction marks are `/Redact` annotations (`EmbedPdf.Annotations.add/3`
  with `subtype: :redact`); `apply_marked/1` applies all of them.
  """

  import EmbedPdf.Edit, only: [f: 1]

  alias EmbedPdf.{Annotation, Annotations, Edit, Font, Forms}
  alias EmbedPdf.PDF.{Content, Document, Filter, Serializer, Stream}
  alias EmbedPdf.Render.{ColorSpace, Matrix}

  @max_depth 12

  @doc "Pending redaction marks of the document."
  @spec pending(Document.t()) :: [Annotation.t()]
  def pending(doc) do
    Enum.flat_map(doc.pages, fn page ->
      doc |> Annotations.list(page.index) |> Enum.filter(&(&1.subtype == :redact))
    end)
  end

  @doc "Applies every `/Redact` annotation and removes the marks."
  @spec apply_marked(Document.t()) :: Document.t()
  def apply_marked(doc) do
    doc
    |> pending()
    |> Enum.group_by(& &1.page)
    |> Enum.reduce(doc, fn {page, marks}, d ->
      d = Enum.reduce(marks, d, &Annotations.delete(&2, &1.id))

      Enum.reduce(marks, d, fn m, d2 ->
        rects = if m.quad_points != [], do: m.quad_points, else: [m.rect]

        apply(d2, page, rects,
          fill: m.interior_color || {0.0, 0.0, 0.0},
          overlay_text: m.overlay_text
        )
      end)
    end)
  end

  @doc """
  Redacts `rects` (PDF user space) on page `page_index`. Options:
  `fill` (`{r, g, b}`, default black; `nil` for no fill), `overlay_text`.
  """
  @spec apply(Document.t(), non_neg_integer(), [tuple()], keyword()) :: Document.t()
  def apply(doc, page_index, rects, opts \\ []) do
    rects =
      rects
      |> Enum.map(&Edit.normalize/1)
      |> Enum.reject(fn {x0, y0, x1, y1} -> x1 - x0 <= 0 or y1 - y0 <= 0 end)

    page = Document.page(doc, page_index)

    if rects == [] or page == nil do
      doc
    else
      fill = Keyword.get(opts, :fill, {0.0, 0.0, 0.0})
      ops = doc |> Document.page_content(page) |> Content.parse()

      ctx = new_ctx(doc, page.resources, Matrix.identity(), rects, fill, 0)
      {out, ctx} = rewrite(ops, ctx)

      {doc, content_ref} =
        Document.add_object(ctx.doc, %Stream{dict: %{}, raw: serialize_ops(out)})

      doc =
        Edit.update_page(doc, page_index, fn dict ->
          dict |> Map.put("Contents", content_ref) |> Map.put("Resources", ctx.resources)
        end)

      doc
      |> remove_annotations(page_index, rects)
      |> paint(page_index, rects, fill, Keyword.get(opts, :overlay_text))
    end
  end

  defp new_ctx(doc, resources, ctm, rects, fill, depth) do
    %{
      doc: doc,
      resources: Document.resolve(doc, resources) || %{},
      rects: rects,
      fill: fill,
      depth: depth,
      gs: %{ctm: ctm, font: nil, size: 0.0, tc: 0.0, tw: 0.0, th: 1.0, tl: 0.0, rise: 0.0},
      stack: [],
      tm: Matrix.identity(),
      tlm: Matrix.identity(),
      fonts: %{},
      path: [],
      clip?: false,
      mc: [],
      strip: MapSet.new(),
      count: 0,
      changed?: false
    }
  end

  # ---------------------------------------------------------------- rewriting

  defp rewrite(ops, ctx) do
    {out, ctx} = Enum.reduce(ops, {[], ctx}, fn op, {out, c} -> step(op, out, c) end)
    out = Enum.reverse(out)

    out =
      if MapSet.size(ctx.strip) == 0 do
        out
      else
        out
        |> Enum.with_index()
        |> Enum.map(fn
          {{"BDC", [tag, %{} = props]}, i} ->
            if MapSet.member?(ctx.strip, i),
              do: {"BDC", [tag, Map.drop(props, ["ActualText", "Alt", "E"])]},
              else: {"BDC", [tag, props]}

          {op, _} ->
            op
        end)
      end

    {out, ctx}
  end

  defp emit(out, ctx, op), do: {[op | out], %{ctx | count: ctx.count + 1}}

  defp step({op, args} = o, out, ctx) do
    try do
      do_step(op, args, o, out, ctx)
    rescue
      _ -> emit(out, ctx, o)
    end
  end

  defp do_step("q", _, o, out, ctx), do: emit(out, %{ctx | stack: [ctx.gs | ctx.stack]}, o)

  defp do_step("Q", _, o, out, ctx) do
    case ctx.stack do
      [gs | rest] -> emit(out, %{ctx | gs: gs, stack: rest}, o)
      [] -> emit(out, ctx, o)
    end
  end

  defp do_step("cm", [a, b, c, d, e, f], o, out, ctx) do
    m = Enum.map([a, b, c, d, e, f], &(&1 / 1))
    emit(out, put_gs(ctx, :ctm, Matrix.multiply(m, ctx.gs.ctm)), o)
  end

  defp do_step("BT", _, o, out, ctx),
    do: emit(out, %{ctx | tm: Matrix.identity(), tlm: Matrix.identity()}, o)

  defp do_step("Tc", [v], o, out, ctx), do: emit(out, put_gs(ctx, :tc, v / 1), o)
  defp do_step("Tw", [v], o, out, ctx), do: emit(out, put_gs(ctx, :tw, v / 1), o)
  defp do_step("Tz", [v], o, out, ctx), do: emit(out, put_gs(ctx, :th, v / 100), o)
  defp do_step("TL", [v], o, out, ctx), do: emit(out, put_gs(ctx, :tl, v / 1), o)
  defp do_step("Ts", [v], o, out, ctx), do: emit(out, put_gs(ctx, :rise, v / 1), o)

  defp do_step("Tf", [name, size], o, out, ctx) do
    {font, ctx} = font(ctx, name)
    emit(out, %{ctx | gs: %{ctx.gs | font: font, size: size / 1}}, o)
  end

  defp do_step("gs", [name], o, out, ctx) do
    case Document.get(ctx.doc, Document.get(ctx.doc, ctx.resources, "ExtGState"), name) do
      %{"Font" => [ref, size]} ->
        font = Font.load(ctx.doc, ref)
        emit(out, %{ctx | gs: %{ctx.gs | font: font, size: size / 1}}, o)

      _ ->
        emit(out, ctx, o)
    end
  end

  defp do_step("Td", [tx, ty], o, out, ctx), do: emit(out, td(ctx, tx, ty), o)

  defp do_step("TD", [tx, ty], o, out, ctx),
    do: emit(out, ctx |> put_gs(:tl, -ty / 1) |> td(tx, ty), o)

  defp do_step("Tm", [a, b, c, d, e, f], o, out, ctx) do
    m = Enum.map([a, b, c, d, e, f], &(&1 / 1))
    emit(out, %{ctx | tm: m, tlm: m}, o)
  end

  defp do_step("T*", _, o, out, ctx), do: emit(out, td(ctx, 0, -ctx.gs.tl), o)

  defp do_step("Tj", [{:string, s}], o, out, ctx), do: show(out, ctx, [{:string, s}], o, [])

  defp do_step("TJ", [items], o, out, ctx) when is_list(items), do: show(out, ctx, items, o, [])

  defp do_step("'", [{:string, s}], _o, out, ctx) do
    {out, ctx} = emit(out, td(ctx, 0, -ctx.gs.tl), {"T*", []})
    show(out, ctx, [{:string, s}], {"Tj", [{:string, s}]}, [])
  end

  defp do_step("\"", [aw, ac, {:string, s}], _o, out, ctx) do
    {out, ctx} = emit(out, put_gs(ctx, :tw, aw / 1), {"Tw", [aw]})
    {out, ctx} = emit(out, put_gs(ctx, :tc, ac / 1), {"Tc", [ac]})
    {out, ctx} = emit(out, td(ctx, 0, -ctx.gs.tl), {"T*", []})
    show(out, ctx, [{:string, s}], {"Tj", [{:string, s}]}, [])
  end

  # paths are buffered until painted
  defp do_step(op, _, o, out, ctx) when op in ["m", "l", "c", "v", "y", "h", "re"],
    do: {out, %{ctx | path: [o | ctx.path]}}

  defp do_step(op, _, o, out, ctx) when op in ["W", "W*"],
    do: {out, %{ctx | path: [o | ctx.path], clip?: true}}

  defp do_step(op, _, o, out, ctx)
       when op in ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"] do
    path = Enum.reverse(ctx.path)
    ctx = %{ctx | path: [], clip?: false}
    clip? = Enum.any?(path, fn {p, _} -> p in ["W", "W*"] end)
    box = path_box(path, ctx.gs.ctm)

    if not clip? and op != "n" and box != nil and Enum.any?(ctx.rects, &Edit.inside?(box, &1)) do
      {out, %{ctx | changed?: true}}
    else
      Enum.reduce(path ++ [o], {out, ctx}, fn p, {o2, c} -> emit(o2, c, p) end)
    end
  end

  defp do_step("Do", [name], o, out, ctx) do
    xobjects = Document.get(ctx.doc, ctx.resources, "XObject") || %{}

    case Document.resolve(ctx.doc, Map.get(xobjects, name)) do
      %Stream{dict: dict} = xobj ->
        case Document.resolve(ctx.doc, dict["Subtype"]) do
          "Image" -> image(out, ctx, name, xobj, o)
          "Form" -> form(out, ctx, xobj, o)
          _ -> emit(out, ctx, o)
        end

      _ ->
        emit(out, ctx, o)
    end
  end

  defp do_step("BI", _, o, out, ctx) do
    box = Matrix.transform_rect(ctx.gs.ctm, {0.0, 0.0, 1.0, 1.0})

    if Enum.any?(ctx.rects, &Edit.overlap?(box, &1)),
      do: {out, %{ctx | changed?: true}},
      else: emit(out, ctx, o)
  end

  defp do_step("BDC", _, o, out, ctx),
    do: emit(out, %{ctx | mc: [{ctx.count, false} | ctx.mc]}, o)

  defp do_step("BMC", _, o, out, ctx), do: emit(out, %{ctx | mc: [{nil, false} | ctx.mc]}, o)

  defp do_step("EMC", _, o, out, ctx) do
    case ctx.mc do
      [{index, true} | rest] ->
        strip = if index, do: MapSet.put(ctx.strip, index), else: ctx.strip
        # the enclosing sequence lost text too
        rest =
          case rest do
            [{i, _} | more] -> [{i, true} | more]
            [] -> []
          end

        emit(out, %{ctx | mc: rest, strip: strip}, o)

      [_ | rest] ->
        emit(out, %{ctx | mc: rest}, o)

      [] ->
        emit(out, ctx, o)
    end
  end

  defp do_step(_op, _args, o, out, ctx), do: emit(out, ctx, o)

  defp put_gs(ctx, key, value), do: %{ctx | gs: Map.put(ctx.gs, key, value)}

  defp td(ctx, tx, ty) do
    tlm = Matrix.multiply(Matrix.translate(tx, ty), ctx.tlm)
    %{ctx | tlm: tlm, tm: tlm}
  end

  defp font(ctx, name) do
    ref =
      case Document.get(ctx.doc, ctx.resources, "Font") do
        %{} = fonts -> Map.get(fonts, name)
        _ -> nil
      end

    key = with {:ref, n, _} <- ref, do: n

    case Map.fetch(ctx.fonts, key) do
      {:ok, font} ->
        {font, ctx}

      :error ->
        font =
          if ref,
            do: Font.load(ctx.doc, ref),
            else: Font.load(ctx.doc, %{"Subtype" => "Type1", "BaseFont" => "Helvetica"})

        {font, %{ctx | fonts: Map.put(ctx.fonts, key, font)}}
    end
  end

  # ---------------------------------------------------------------- text

  defp show(out, %{gs: %{font: nil}} = ctx, items, o, acc) do
    {font, ctx} = font(ctx, nil)
    show(out, %{ctx | gs: %{ctx.gs | font: font}}, items, o, acc)
  end

  defp show(out, ctx, items, original, _acc) do
    gs = ctx.gs
    font = gs.font
    fs = gs.size
    th = gs.th

    {parts, tm, removed?} =
      Enum.reduce(items, {[], ctx.tm, false}, fn
        {:string, bytes}, {parts, tm, removed?} ->
          {glyph_parts, tm, r} = glyphs(font, bytes, tm, ctx)
          {parts ++ glyph_parts, tm, removed? or r}

        n, {parts, tm, removed?} when is_number(n) ->
          tm =
            if font.vertical?,
              do: Matrix.multiply(Matrix.translate(0, -n / 1000 * fs), tm),
              else: Matrix.multiply(Matrix.translate(-n / 1000 * fs * th, 0), tm)

          {parts ++ [{:kern, n / 1}], tm, removed?}

        _, acc ->
          acc
      end)

    ctx = %{ctx | tm: tm}

    if removed? do
      ctx = %{ctx | changed?: true, mc: Enum.map(ctx.mc, fn {i, _} -> {i, true} end)}
      emit(out, ctx, {"TJ", [merge_parts(parts)]})
    else
      emit(out, ctx, original)
    end
  end

  # glyphs of one string: {[{:keep, bytes} | {:kern, n}], new_tm, removed?}
  defp glyphs(font, bytes, tm, ctx) do
    gs = ctx.gs
    fs = gs.size
    th = gs.th
    asc = font.ascent |> max(0.5) |> min(1.2)
    desc = font.descent |> min(-0.05) |> max(-0.5)

    {parts, tm, removed?, _rest} =
      font
      |> Font.decode(bytes)
      |> Enum.reduce({[], tm, false, bytes}, fn {code, _cid, _uni, w0, n},
                                                {parts, tm, removed?, rest} ->
        <<glyph_bytes::binary-size(n), rest::binary>> = rest

        trm =
          [fs * th, 0.0, 0.0, fs, 0.0, gs.rise] |> Matrix.multiply(tm) |> Matrix.multiply(gs.ctm)

        width = if w0 <= 0, do: 0.5, else: w0
        box = Matrix.transform_rect(trm, {0.0, desc, width, asc})
        word = if code == 32 and n == 1, do: gs.tw, else: 0.0

        {advance, next_tm} =
          if font.vertical? do
            ty = -(1.0 * fs) + gs.tc + word
            {ty, Matrix.multiply(Matrix.translate(0, ty), tm)}
          else
            tx = (w0 * fs + gs.tc + word) * th
            {tx, Matrix.multiply(Matrix.translate(tx, 0), tm)}
          end

        if fs != 0 and hit?(box, ctx.rects) do
          kern = if font.vertical?, do: -advance * 1000 / fs, else: -advance * 1000 / (fs * th)
          {[{:kern, kern} | parts], next_tm, true, rest}
        else
          {[{:keep, glyph_bytes} | parts], next_tm, removed?, rest}
        end
      end)

    {Enum.reverse(parts), tm, removed?}
  end

  defp hit?({x0, y0, x1, y1} = box, rects) do
    area = max((x1 - x0) * (y1 - y0), 1.0e-6)
    cx = (x0 + x1) / 2
    cy = (y0 + y1) / 2

    Enum.any?(rects, fn {a0, b0, a1, b1} = r ->
      (cx >= a0 and cx <= a1 and cy >= b0 and cy <= b1) or Edit.overlap_area(box, r) / area > 0.1
    end)
  end

  defp merge_parts(parts) do
    parts
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(fn
      [{:keep, _} | _] = keeps ->
        {:string, keeps |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()}

      [{:kern, _} | _] = kerns ->
        kerns |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> Float.round(3)
    end)
  end

  # ---------------------------------------------------------------- paths

  defp path_box(path, ctm) do
    points =
      Enum.flat_map(path, fn
        {"m", [x, y]} -> [{x, y}]
        {"l", [x, y]} -> [{x, y}]
        {"c", [a, b, c, d, e, f]} -> [{a, b}, {c, d}, {e, f}]
        {"v", [a, b, c, d]} -> [{a, b}, {c, d}]
        {"y", [a, b, c, d]} -> [{a, b}, {c, d}]
        {"re", [x, y, w, h]} -> [{x, y}, {x + w, y + h}]
        _ -> []
      end)
      |> Enum.map(fn {x, y} -> Matrix.apply(ctm, x, y) end)

    if points == [], do: nil, else: Edit.bbox(points)
  end

  # ---------------------------------------------------------------- images

  defp image(out, ctx, name, %Stream{dict: dict} = img, o) do
    box = Matrix.transform_rect(ctx.gs.ctm, {0.0, 0.0, 1.0, 1.0})
    hits = Enum.filter(ctx.rects, &Edit.overlap?(box, &1))

    cond do
      hits == [] ->
        emit(out, ctx, o)

      true ->
        case paint_image(ctx, dict, img, hits) do
          {:ok, new_stream} ->
            {doc, ref} = Document.add_object(ctx.doc, new_stream)
            new_name = Edit.fresh_name(doc, ctx.resources, "XObject", name <> "R")

            resources =
              Edit.merge_resources(doc, ctx.resources, %{"XObject" => %{new_name => ref}})

            emit(out, %{ctx | doc: doc, resources: resources, changed?: true}, {"Do", [new_name]})

          :drop ->
            {out, %{ctx | changed?: true}}
        end
    end
  end

  defp paint_image(ctx, dict, img, hits) do
    doc = ctx.doc
    r = fn k -> Document.resolve(doc, dict[k]) end
    filters = r.("Filter") |> List.wrap() |> Enum.map(&Document.resolve(doc, &1))
    params = r.("DecodeParms")
    w = r.("Width")
    h = r.("Height")
    bpc = r.("BitsPerComponent") || 8

    with false <- r.("ImageMask") == true,
         true <- is_integer(w) and is_integer(h) and w > 0 and h > 0,
         8 <- bpc,
         {data, nil} <- Filter.decode(img.raw, filters, params),
         cs = ColorSpace.parse(doc, r.("ColorSpace"), ctx.resources),
         n when n in [1, 3, 4] <- ColorSpace.components(cs),
         true <- byte_size(data) >= w * h * n do
      fill_bytes = fill_bytes(cs, ctx.fill, n)
      inverse = Matrix.invert(ctx.gs.ctm)

      regions =
        Enum.map(hits, fn rect ->
          {u0, v0, u1, v1} = Matrix.transform_rect(inverse, rect)
          px0 = (u0 * w) |> floor() |> max(0) |> min(w)
          px1 = (u1 * w) |> ceil() |> max(0) |> min(w)
          py0 = ((1 - v1) * h) |> floor() |> max(0) |> min(h)
          py1 = ((1 - v0) * h) |> ceil() |> max(0) |> min(h)
          {px0, px1, py0, py1}
        end)

      row_len = w * n

      rows =
        for y <- 0..(h - 1) do
          row = binary_part(data, y * row_len, row_len)

          Enum.reduce(regions, row, fn {x0, x1, y0, y1}, row ->
            if y >= y0 and y < y1 and x1 > x0 do
              before = binary_part(row, 0, x0 * n)
              after_ = binary_part(row, x1 * n, row_len - x1 * n)
              before <> :binary.copy(fill_bytes, x1 - x0) <> after_
            else
              row
            end
          end)
        end

      new_dict =
        dict
        |> Map.put("Filter", "FlateDecode")
        |> Map.delete("DecodeParms")
        |> Map.delete("Length")

      {:ok, %Stream{dict: new_dict, raw: :zlib.compress(rows)}}
    else
      _ -> :drop
    end
  end

  defp fill_bytes(:gray, {r, g, b}, _), do: <<round((0.3 * r + 0.59 * g + 0.11 * b) * 255)>>
  defp fill_bytes(:rgb, {r, g, b}, _), do: <<round(r * 255), round(g * 255), round(b * 255)>>

  defp fill_bytes(:cmyk, {r, g, b}, _) do
    k = 1 - Enum.max([r, g, b])
    d = max(1 - k, 1.0e-6)
    c = (1 - r - k) / d
    m = (1 - g - k) / d
    y = (1 - b - k) / d
    <<round(c * 255), round(m * 255), round(y * 255), round(k * 255)>>
  end

  defp fill_bytes({:indexed, base, hival, lookup}, color, _) do
    best =
      Enum.min_by(
        0..hival//1,
        fn i ->
          {r, g, b} = ColorSpace.to_rgb({:indexed, base, hival, lookup}, [i])
          {fr, fg, fb} = color
          (r - fr) ** 2 + (g - fg) ** 2 + (b - fb) ** 2
        end,
        fn -> 0 end
      )

    <<best>>
  end

  defp fill_bytes(_cs, _color, n), do: :binary.copy(<<0>>, n)

  # ---------------------------------------------------------------- forms

  defp form(out, ctx, %Stream{dict: dict} = xobj, o) do
    doc = ctx.doc
    matrix = Matrix.from_pdf(Document.resolve(doc, dict["Matrix"]))
    ctm = Matrix.multiply(matrix, ctx.gs.ctm)
    bbox = EmbedPdf.PDF.Page.normalize_rect(Document.resolve(doc, dict["BBox"]), doc)
    box = if bbox, do: Matrix.transform_rect(ctm, bbox), else: nil

    cond do
      ctx.depth >= @max_depth ->
        emit(out, ctx, o)

      box != nil and not Enum.any?(ctx.rects, &Edit.overlap?(box, &1)) ->
        emit(out, ctx, o)

      true ->
        resources = Document.resolve(doc, dict["Resources"]) || ctx.resources
        inner = new_ctx(doc, resources, ctm, ctx.rects, ctx.fill, ctx.depth + 1)
        {inner_out, inner} = rewrite(Content.parse(Document.stream_data(doc, xobj) || ""), inner)

        if inner.changed? do
          new_form = %Stream{
            dict:
              dict
              |> Map.put("Resources", inner.resources)
              |> Map.delete("Filter")
              |> Map.delete("DecodeParms")
              |> Map.delete("Length"),
            raw: serialize_ops(inner_out)
          }

          {doc, ref} = Document.add_object(inner.doc, new_form)
          [name] = elem(o, 1)
          new_name = Edit.fresh_name(doc, ctx.resources, "XObject", name <> "R")
          res = Edit.merge_resources(doc, ctx.resources, %{"XObject" => %{new_name => ref}})

          mc =
            if Enum.any?(inner_out, &match?({"TJ", _}, &1)),
              do: Enum.map(ctx.mc, fn {i, _} -> {i, true} end),
              else: ctx.mc

          emit(out, %{ctx | doc: doc, resources: res, changed?: true, mc: mc}, {"Do", [new_name]})
        else
          emit(out, %{ctx | doc: inner.doc}, o)
        end
    end
  end

  # ---------------------------------------------------------------- output

  @doc false
  def serialize_ops(ops),
    do: ops |> Enum.map(&serialize_op/1) |> Enum.intersperse("\n") |> IO.iodata_to_binary()

  defp serialize_op({"BI", [%{dict: dict, data: data}]}) do
    entries = Enum.map(dict, fn {k, v} -> [Serializer.serialize(k), " ", value(v), " "] end)
    ["BI ", entries, "ID ", data, "\nEI"]
  end

  defp serialize_op({op, []}), do: op

  defp serialize_op({op, args}),
    do: [args |> Enum.map(&value/1) |> Enum.intersperse(" "), " ", op]

  # numbers are written back exactly (the serializer rounds to 5 decimals)
  defp value(f) when is_float(f) do
    short = :erlang.float_to_binary(f, [:short])

    if String.contains?(short, "e"),
      do:
        f
        |> :erlang.float_to_binary(decimals: 12)
        |> String.trim_trailing("0")
        |> String.trim_trailing("."),
      else: String.replace_suffix(short, ".0", "")
  end

  defp value(list) when is_list(list),
    do: ["[", list |> Enum.map(&value/1) |> Enum.intersperse(" "), "]"]

  defp value(map) when is_map(map) and not is_struct(map),
    do: [
      "<<",
      Enum.map(map, fn {k, v} -> [Serializer.serialize(k), " ", value(v), " "] end),
      ">>"
    ]

  defp value(v), do: Serializer.serialize(v)

  # ---------------------------------------------------------------- annotations & fill

  defp remove_annotations(doc, page_index, rects) do
    doomed =
      doc
      |> Annotations.all_on_page(page_index)
      |> Enum.filter(fn a -> a.id && a.rect && Enum.any?(rects, &Edit.overlap?(a.rect, &1)) end)

    widgets = doomed |> Enum.filter(&(&1.subtype == :widget)) |> Enum.map(& &1.id)
    doc = Enum.reduce(doomed, doc, &Annotations.delete(&2, &1.id))
    if widgets == [], do: doc, else: Forms.remove_widgets(doc, widgets)
  end

  defp paint(doc, _page_index, _rects, nil, nil), do: doc

  defp paint(doc, page_index, rects, fill, overlay) do
    fill_ops =
      if fill do
        {r, g, b} = fill

        [
          f(Edit.num(r)),
          " ",
          f(Edit.num(g)),
          " ",
          f(Edit.num(b)),
          " rg\n",
          Enum.map(rects, fn {x0, y0, x1, y1} ->
            [f(x0), " ", f(y0), " ", f(x1 - x0), " ", f(y1 - y0), " re\n"]
          end),
          "f\n"
        ]
      else
        []
      end

    {text_ops, resources} =
      case overlay do
        text when is_binary(text) and text != "" ->
          {fr, fg, fb} = fill || {1.0, 1.0, 1.0}
          dark? = 0.3 * fr + 0.59 * fg + 0.11 * fb < 0.5
          color = if dark?, do: "1 g", else: "0 g"

          ops =
            Enum.map(rects, fn {x0, y0, x1, y1} ->
              size = min((y1 - y0) * 0.7, 14.0)
              tw = Edit.text_width(text, "Helvetica", size)
              size = if tw > x1 - x0 - 2 and tw > 0, do: size * (x1 - x0 - 2) / tw, else: size
              tw = Edit.text_width(text, "Helvetica", size)

              [
                "BT /RdHelv ",
                f(size),
                " Tf ",
                color,
                " 1 0 0 1 ",
                f(x0 + (x1 - x0 - tw) / 2),
                " ",
                f(y0 + (y1 - y0 - size * 0.7) / 2),
                " Tm ",
                Edit.tj(text),
                " ET\n"
              ]
            end)

          {ops, %{"Font" => %{"RdHelv" => Edit.std_font_dict("Helvetica")}}}

        _ ->
          {[], %{}}
      end

    Edit.append_content(doc, page_index, ["q\n", fill_ops, text_ops, "Q"], resources)
  end
end
