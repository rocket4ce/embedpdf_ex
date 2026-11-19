defmodule EmbedPdf.Render.Shading do
  @moduledoc """
  Shadings (ISO 32000-1, 8.7.4.5) as SVG paint.

    * types 2 and 3 (axial, radial) become `linearGradient` / `radialGradient`
      with stops sampled from the shading function; `/Extend false` ends
      become transparent
    * type 1 (function-based) is sampled into a small PNG
    * types 4–7 (meshes) are approximated by flat-colored triangles
  """

  alias EmbedPdf.PDF.{Document, Stream}
  alias EmbedPdf.Render.{ColorSpace, Matrix, PNG}
  alias EmbedPdf.Render.Function, as: Fun

  @stops 32

  @type paint ::
          {:gradient, iodata()}
          | {:image, String.t(), Matrix.t()}
          | {:triangles, [{[{float(), float()}], {float(), float(), float()}}]}
          | {:fill, {float(), float(), float()}}
          | :skip

  @doc """
  Builds paint for a shading drawn in a space mapped to the referencing
  element's user space by `transform`. Gradients are returned as complete
  `<linearGradient id=...>` / `<radialGradient>` elements.
  """
  @spec paint(Document.t(), term(), Matrix.t(), String.t(), map() | nil) :: paint()
  def paint(doc, shading, transform, id, resources \\ nil) do
    {dict, stream} =
      case Document.resolve(doc, shading) do
        %Stream{dict: d} = s -> {d, s}
        %{} = d -> {d, nil}
        _ -> {nil, nil}
      end

    if dict do
      get = &Document.resolve(doc, dict[&1])
      cs = ColorSpace.parse(doc, get.("ColorSpace") || "DeviceGray", resources)
      func = Fun.parse(doc, dict["Function"])

      case get.("ShadingType") do
        2 ->
          axial(doc, get, cs, func, transform, id)

        3 ->
          radial(doc, get, cs, func, transform, id)

        1 ->
          function_based(get, cs, func, transform)

        t when t in [4, 5, 6, 7] and stream != nil ->
          mesh(doc, t, dict, stream, cs, func, transform)

        _ ->
          :skip
      end
    else
      :skip
    end
  rescue
    _ -> :skip
  end

  defp color(cs, func, t) do
    comps = if func, do: Fun.eval(func, [t]), else: [t]
    ColorSpace.to_rgb(cs, comps)
  end

  defp nums(list, n, default) when is_list(list) do
    if length(list) >= n and Enum.all?(Enum.take(list, n), &is_number/1),
      do: Enum.map(Enum.take(list, n), &(&1 / 1)),
      else: default
  end

  defp nums(_, _, default), do: default

  defp extend(get) do
    case get.("Extend") do
      [a, b | _] -> {a == true, b == true}
      _ -> {false, false}
    end
  end

  defp stops(cs, func, [t0, t1], {e0, e1}, reverse?) do
    samples =
      for i <- 0..@stops do
        f = i / @stops
        t = t0 + (t1 - t0) * f
        {if(reverse?, do: 1 - f, else: f), color(cs, func, t)}
      end

    samples = if reverse?, do: Enum.reverse(samples), else: samples
    {first_off, first_c} = hd(samples)
    {last_off, last_c} = List.last(samples)
    {start_extend, end_extend} = if reverse?, do: {e1, e0}, else: {e0, e1}

    head = if start_extend, do: [], else: [stop(first_off, first_c, 0)]
    tail = if end_extend, do: [], else: [stop(last_off, last_c, 0)]

    [head, Enum.map(samples, fn {o, c} -> stop(o, c, 1) end), tail]
  end

  defp stop(offset, rgb, opacity) do
    [
      ~s(<stop offset="),
      n(offset),
      ~s(" stop-color="),
      ColorSpace.hex(rgb),
      ~s("),
      if(opacity == 1, do: "", else: ~s( stop-opacity="0")),
      "/>"
    ]
  end

  defp axial(_doc, get, cs, func, transform, id) do
    case nums(get.("Coords"), 4, nil) do
      [x0, y0, x1, y1] ->
        domain = nums(get.("Domain"), 2, [0.0, 1.0])

        {:gradient,
         [
           ~s(<linearGradient id="),
           id,
           ~s(" gradientUnits="userSpaceOnUse" x1="),
           n(x0),
           ~s(" y1="),
           n(y0),
           ~s(" x2="),
           n(x1),
           ~s(" y2="),
           n(y1),
           ~s(" gradientTransform="),
           matrix(transform),
           ~s(">),
           stops(cs, func, domain, extend(get), false),
           "</linearGradient>"
         ]}

      _ ->
        :skip
    end
  end

  defp radial(_doc, get, cs, func, transform, id) do
    case nums(get.("Coords"), 6, nil) do
      [x0, y0, r0, x1, y1, r1] ->
        domain = nums(get.("Domain"), 2, [0.0, 1.0])
        reverse? = r0 > r1

        {fx, fy, fr, cx, cy, r} =
          if reverse?, do: {x1, y1, r1, x0, y0, r0}, else: {x0, y0, r0, x1, y1, r1}

        {:gradient,
         [
           ~s(<radialGradient id="),
           id,
           ~s(" gradientUnits="userSpaceOnUse" fx="),
           n(fx),
           ~s(" fy="),
           n(fy),
           ~s(" fr="),
           n(fr),
           ~s(" cx="),
           n(cx),
           ~s(" cy="),
           n(cy),
           ~s(" r="),
           n(max(r, 0.001)),
           ~s(" gradientTransform="),
           matrix(transform),
           ~s(">),
           stops(cs, func, domain, extend(get), reverse?),
           "</radialGradient>"
         ]}

      _ ->
        :skip
    end
  end

  defp function_based(get, cs, func, transform) do
    [x0, x1, y0, y1] = nums(get.("Domain"), 4, [0.0, 1.0, 0.0, 1.0])
    m = Matrix.from_pdf(get.("Matrix"))
    size = 48

    rows =
      for j <- (size - 1)..0//-1 do
        y = y0 + (y1 - y0) * (j + 0.5) / size

        for i <- 0..(size - 1), into: <<>> do
          x = x0 + (x1 - x0) * (i + 0.5) / size
          comps = if func, do: Fun.eval(func, [x, y]), else: [x, y]
          {r, g, b} = ColorSpace.to_rgb(cs, comps)
          <<round(r * 255), round(g * 255), round(b * 255)>>
        end
      end

    png = PNG.encode(size, size, :rgb, 8, rows)
    unit = [x1 - x0, 0.0, 0.0, y1 - y0, x0, y0]
    {:image, PNG.data_uri(png), unit |> Matrix.multiply(m) |> Matrix.multiply(transform)}
  end

  # ---------------------------------------------------------------- meshes

  defp mesh(doc, type, dict, stream, cs, func, transform) do
    get = &Document.resolve(doc, dict[&1])
    data = Document.stream_data(doc, stream) || <<>>
    bpcoord = get.("BitsPerCoordinate") || 16
    bpcomp = get.("BitsPerComponent") || 8
    bpflag = get.("BitsPerFlag") || 8
    ncomp = if func, do: 1, else: ColorSpace.components(cs)
    decode = nums(get.("Decode"), 4 + 2 * ncomp, nil)

    if decode == nil do
      :skip
    else
      reader = %{bc: bpcoord, bk: bpcomp, bf: bpflag, n: ncomp, decode: decode}

      to_rgb = fn comps ->
        if func,
          do: ColorSpace.to_rgb(cs, Fun.eval(func, comps)),
          else: ColorSpace.to_rgb(cs, comps)
      end

      tris =
        case type do
          4 -> free_triangles(data, reader)
          5 -> lattice(data, reader, get.("VerticesPerRow") || 2)
          6 -> patches(data, reader, 12)
          7 -> patches(data, reader, 16)
        end

      triangles =
        tris
        |> Enum.take(20_000)
        |> Enum.map(fn {pts, colors} ->
          avg =
            colors
            |> Enum.zip()
            |> Enum.map(fn t -> t |> Tuple.to_list() |> Enum.sum() |> Kernel./(tuple_size(t)) end)

          {Enum.map(pts, fn {x, y} -> Matrix.apply(transform, x, y) end), to_rgb.(avg)}
        end)

      if triangles == [], do: :skip, else: {:triangles, triangles}
    end
  end

  # vertices: {flag?, {x, y}, comps}
  defp read_vertex(bits, r, with_flag?) do
    with {flag, bits} <- if(with_flag?, do: take(bits, r.bf), else: {0, bits}),
         {x, bits} when is_integer(x) <- take(bits, r.bc),
         {y, bits} when is_integer(y) <- take(bits, r.bc),
         {comps, bits} when is_list(comps) <- take_comps(bits, r.bk, r.n, []) do
      [xmin, xmax, ymin, ymax | cdec] = r.decode
      xv = xmin + x * (xmax - xmin) / (pow2(r.bc) - 1)
      yv = ymin + y * (ymax - ymin) / (pow2(r.bc) - 1)

      cv =
        comps
        |> Enum.with_index()
        |> Enum.map(fn {c, i} ->
          lo = Enum.at(cdec, 2 * i, 0)
          hi = Enum.at(cdec, 2 * i + 1, 1)
          lo + c * (hi - lo) / (pow2(r.bk) - 1)
        end)

      {:ok, flag, {xv, yv}, cv, bits}
    else
      _ -> :eof
    end
  end

  defp pow2(b), do: Bitwise.bsl(1, b)

  defp take(bits, n) do
    case bits do
      <<v::size(n), rest::bitstring>> -> {v, rest}
      _ -> :eof
    end
  end

  defp take_comps(bits, _bk, 0, acc), do: {Enum.reverse(acc), bits}

  defp take_comps(bits, bk, n, acc) do
    case take(bits, bk) do
      {v, rest} -> take_comps(rest, bk, n - 1, [v | acc])
      :eof -> :eof
    end
  end

  # every vertex of a free-form mesh starts on a byte boundary
  defp free_triangles(data, r), do: free_loop(data, r, nil, [])

  defp free_loop(bits, r, prev, acc) do
    case read_vertex(bits, r, true) do
      {:ok, flag, p, c, rest} ->
        rest = skip_to_byte(rest)
        v = {p, c}

        case {flag, prev} do
          {f, {a, b, cc}} when f in [1, 2] ->
            t = if f == 1, do: {b, cc, v}, else: {a, cc, v}
            free_loop(rest, r, t, [tri3(t) | acc])

          _ ->
            with {:ok, _, p2, c2, rest2} <- read_vertex(rest, r, true),
                 {:ok, _, p3, c3, rest3} <- read_vertex(skip_to_byte(rest2), r, true) do
              t = {v, {p2, c2}, {p3, c3}}
              free_loop(skip_to_byte(rest3), r, t, [tri3(t) | acc])
            else
              _ -> Enum.reverse(acc)
            end
        end

      :eof ->
        Enum.reverse(acc)
    end
  end

  defp tri3({a, b, c}), do: tri(a, b, c)

  defp skip_to_byte(bits) do
    pad = rem(bit_size(bits), 8)
    <<_::size(pad), rest::binary>> = bits
    rest
  end

  defp tri({p1, c1}, {p2, c2}, {p3, c3}), do: {[p1, p2, p3], [c1, c2, c3]}

  defp lattice(data, r, per_row) do
    vertices = read_all(data, r, [])
    rows = Enum.chunk_every(vertices, max(per_row, 2), max(per_row, 2), :discard)

    rows
    |> Enum.zip(Enum.drop(rows, 1))
    |> Enum.flat_map(fn {top, bottom} ->
      Enum.zip([top, Enum.drop(top, 1), bottom, Enum.drop(bottom, 1)])
      |> Enum.flat_map(fn {a, b, c, d} -> [tri(a, b, c), tri(b, d, c)] end)
    end)
  end

  defp read_all(bits, r, acc) do
    case read_vertex(bits, r, false) do
      {:ok, _, p, c, rest} -> read_all(rest, r, [{p, c} | acc])
      :eof -> Enum.reverse(acc)
    end
  end

  # Coons (12 points) and tensor (16 points) patches, approximated by the
  # bilinear surface through their corners, split into a 4×4 grid.
  defp patches(data, r, npts) do
    patch_loop(data, r, npts, nil, [])
  end

  defp patch_loop(bits, r, npts, prev, acc) do
    with {flag, bits} when is_integer(flag) <- take(bits, r.bf),
         shared = if(flag == 0, do: 0, else: 4),
         {:ok, pts, bits} <- read_points(bits, r, npts - shared, []),
         {:ok, colors, bits} <- read_colors(bits, r, if(flag == 0, do: 4, else: 2), []) do
      bits = skip_to_byte(bits)

      {pts, colors} =
        case {flag, prev} do
          {0, _} -> {pts, colors}
          {_, nil} -> {pts, colors}
          {f, {ppts, pcolors}} -> share(f, ppts, pcolors, pts, colors)
        end

      if length(pts) >= 12 and length(colors) == 4 do
        patch_loop(bits, r, npts, {pts, colors}, subdivide(pts, colors, npts) ++ acc)
      else
        Enum.reverse(acc)
      end
    else
      _ -> Enum.reverse(acc)
    end
  end

  defp read_points(bits, _r, 0, acc), do: {:ok, Enum.reverse(acc), bits}

  defp read_points(bits, r, n, acc) do
    with {x, bits} when is_integer(x) <- take(bits, r.bc),
         {y, bits} when is_integer(y) <- take(bits, r.bc) do
      [xmin, xmax, ymin, ymax | _] = r.decode

      p =
        {xmin + x * (xmax - xmin) / (pow2(r.bc) - 1), ymin + y * (ymax - ymin) / (pow2(r.bc) - 1)}

      read_points(bits, r, n - 1, [p | acc])
    else
      _ -> :eof
    end
  end

  defp read_colors(bits, _r, 0, acc), do: {:ok, Enum.reverse(acc), bits}

  defp read_colors(bits, r, n, acc) do
    case take_comps(bits, r.bk, r.n, []) do
      {comps, bits} ->
        [_, _, _, _ | cdec] = r.decode

        cv =
          comps
          |> Enum.with_index()
          |> Enum.map(fn {c, i} ->
            lo = Enum.at(cdec, 2 * i, 0)
            hi = Enum.at(cdec, 2 * i + 1, 1)
            lo + c * (hi - lo) / (pow2(r.bk) - 1)
          end)

        read_colors(bits, r, n - 1, [cv | acc])

      :eof ->
        :eof
    end
  end

  # Edge sharing (flags 1–3) for Coons patches: the shared edge's 4 points
  # and 2 colors come from the previous patch.
  defp share(flag, p, c, pts, colors) do
    {edge, ecolors} =
      case flag do
        1 -> {Enum.slice(p, 3, 4), [Enum.at(c, 1), Enum.at(c, 2)]}
        2 -> {Enum.slice(p, 6, 4), [Enum.at(c, 2), Enum.at(c, 3)]}
        _ -> {Enum.slice(p, 9, 3) ++ [Enum.at(p, 0)], [Enum.at(c, 3), Enum.at(c, 0)]}
      end

    {edge ++ pts, ecolors ++ colors}
  end

  defp subdivide(pts, colors, _npts) do
    # corners of a Coons patch: points 0, 3, 6, 9 with colors 0..3
    [p00, p01, p11, p10] = [Enum.at(pts, 0), Enum.at(pts, 3), Enum.at(pts, 6), Enum.at(pts, 9)]
    [c00, c01, c11, c10] = colors
    steps = 4

    at = fn u, v ->
      bil = fn a, b, c, d ->
        a * (1 - u) * (1 - v) + b * (1 - u) * v + c * u * v + d * u * (1 - v)
      end

      {x, y} =
        {bil.(elem(p00, 0), elem(p01, 0), elem(p11, 0), elem(p10, 0)),
         bil.(elem(p00, 1), elem(p01, 1), elem(p11, 1), elem(p10, 1))}

      col = Enum.zip([c00, c01, c11, c10]) |> Enum.map(fn {a, b, c, d} -> bil.(a, b, c, d) end)
      {{x, y}, col}
    end

    for i <- 0..(steps - 1), j <- 0..(steps - 1), reduce: [] do
      acc ->
        u0 = i / steps
        u1 = (i + 1) / steps
        v0 = j / steps
        v1 = (j + 1) / steps
        a = at.(u0, v0)
        b = at.(u0, v1)
        c = at.(u1, v1)
        d = at.(u1, v0)
        [tri(a, b, c), tri(a, c, d) | acc]
    end
  end

  # ---------------------------------------------------------------- formatting

  @doc false
  def n(x) when is_integer(x), do: Integer.to_string(x)

  def n(x) do
    r = round(x * 1000)

    if rem(r, 1000) == 0,
      do: Integer.to_string(div(r, 1000)),
      else: :erlang.float_to_binary(r / 1000, [:compact, decimals: 3])
  end

  @doc false
  def matrix([a, b, c, d, e, f]) do
    sig = &EmbedPdf.Render.SVG.sig/1

    [
      "matrix(",
      sig.(a),
      " ",
      sig.(b),
      " ",
      sig.(c),
      " ",
      sig.(d),
      " ",
      sig.(e),
      " ",
      sig.(f),
      ")"
    ]
  end

  @doc false
  def n4(x) do
    r = round(x * 10_000)

    if rem(r, 10_000) == 0,
      do: Integer.to_string(div(r, 10_000)),
      else: :erlang.float_to_binary(r / 10_000, [:compact, decimals: 4])
  end
end
