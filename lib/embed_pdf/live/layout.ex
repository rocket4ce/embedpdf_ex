defmodule EmbedPdf.Live.Layout do
  @moduledoc """
  Pure page-layout math for the viewer: zoom levels, fit modes, spreads,
  rotation and the mapping between pixels on screen and PDF points.

  The container size comes from the CSS probe (see `EmbedPdf.Live.Probe`),
  so fit-to-width and fit-to-page are computed on the server, exactly like
  a JavaScript viewer would, and click positions map back to the page.
  """

  @gap 12
  @zoom_steps [
    0.1,
    0.25,
    0.33,
    0.5,
    0.67,
    0.75,
    0.8,
    0.9,
    1.0,
    1.1,
    1.25,
    1.5,
    1.75,
    2.0,
    2.5,
    3.0,
    4.0,
    5.0,
    6.0,
    8.0,
    10.0
  ]
  @min_zoom 0.1
  @max_zoom 10.0

  def gap, do: @gap
  def zoom_steps, do: @zoom_steps

  @type zoom :: %{mode: :fit_width | :fit_page | :automatic | :absolute, factor: float()}

  @doc "Displayed size of a page `{w, h}` (points) under a view rotation."
  def rotated({w, h}, rot) when rot in [90, 270], do: {h, w}
  def rotated(size, _), do: size

  @doc """
  Groups page indices into rows for a spread mode (`:none`, `:odd`, `:even`).
  `:odd` puts the first page alone (book covers), `:even` pairs from page 1.
  """
  @spec rows(non_neg_integer(), :none | :odd | :even) :: [[non_neg_integer()]]
  def rows(0, _), do: []
  def rows(count, :none), do: Enum.map(0..(count - 1), &[&1])
  def rows(count, :even), do: 0..(count - 1) |> Enum.chunk_every(2)

  def rows(count, :odd) do
    [[0] | if(count > 1, do: Enum.chunk_every(1..(count - 1), 2), else: [])]
  end

  @doc "The row containing `page`."
  def row_of(rows, page), do: Enum.find(rows, [page], &(page in &1))

  @doc """
  Pixels per point for a zoom given the pages' displayed sizes, the rows
  and the container `{width, height}` in CSS pixels.
  """
  @spec scale(zoom(), [{number(), number()}], [[integer()]], {number(), number()}) :: float()
  def scale(%{mode: :absolute, factor: f}, _sizes, _rows, _container), do: clamp(f)

  def scale(%{mode: mode, factor: f}, sizes, rows, {cw, ch}) do
    sizes = List.to_tuple(sizes)

    {row_w, row_h} =
      rows
      |> Enum.map(fn row ->
        ws = Enum.map(row, &(sizes |> elem(&1) |> elem(0)))
        hs = Enum.map(row, &(sizes |> elem(&1) |> elem(1)))
        {Enum.sum(ws) + @gap * (length(row) - 1) / 1, Enum.max(hs)}
      end)
      |> Enum.reduce({1.0, 1.0}, fn {w, h}, {mw, mh} -> {max(w, mw), max(h, mh)} end)

    fit_w = max(cw - 2 * @gap, 50) / row_w
    fit_h = max(ch - 2 * @gap, 50) / row_h

    base =
      case mode do
        :fit_width -> fit_w
        :fit_page -> min(fit_w, fit_h)
        :automatic -> min(fit_w, 1.0)
      end

    clamp(base * f)
  end

  defp clamp(s), do: s |> max(@min_zoom) |> min(@max_zoom) |> Kernel./(1)

  @doc "Next zoom step above (`:in`) or below (`:out`) the current scale."
  @spec step(float(), :in | :out) :: float()
  def step(current, :in), do: Enum.find(@zoom_steps, @max_zoom, &(&1 > current * 1.01))

  def step(current, :out),
    do: @zoom_steps |> Enum.reverse() |> Enum.find(@min_zoom, &(&1 < current * 0.99))

  @doc "Label for the zoom control."
  def label(%{mode: :absolute}, scale), do: "#{round(scale * 100)}%"
  def label(%{mode: _, factor: f}, scale) when f != 1.0, do: "#{round(scale * 100)}%"
  def label(%{mode: _}, scale), do: "#{round(scale * 100)}%"

  @doc """
  Rotates a rectangle given in displayed coordinates of an unrotated view
  (page size `{w, h}`) by a further clockwise `rot`.
  """
  @spec rotate_rect({number(), number(), number(), number()}, {number(), number()}, integer()) ::
          {float(), float(), float(), float()}
  def rotate_rect(rect, _size, 0), do: rect

  def rotate_rect({x0, y0, x1, y1}, {w, h}, rot) do
    {a0, b0} = rotate_point({x0, y0}, {w, h}, rot)
    {a1, b1} = rotate_point({x1, y1}, {w, h}, rot)
    {min(a0, a1), min(b0, b1), max(a0, a1), max(b0, b1)}
  end

  @doc "Rotates a displayed point clockwise by `rot` within a page of size `{w, h}`."
  def rotate_point(p, _size, 0), do: p
  def rotate_point({x, y}, {_w, h}, 90), do: {h - y, x}
  def rotate_point({x, y}, {w, h}, 180), do: {w - x, h - y}
  def rotate_point({x, y}, {w, _h}, 270), do: {y, w - x}

  @doc "Inverse of `rotate_point/3`."
  def unrotate_point(p, _size, 0), do: p
  def unrotate_point({x, y}, {_w, h}, 90), do: {y, h - x}
  def unrotate_point({x, y}, {w, h}, 180), do: {w - x, h - y}
  def unrotate_point({x, y}, {w, _h}, 270), do: {w - y, x}

  @doc "A rectangle as CSS percentages of a page of size `{w, h}`."
  @spec percent_style({number(), number(), number(), number()}, {number(), number()}) ::
          String.t()
  def percent_style({x0, y0, x1, y1}, {w, h}) do
    "left:#{pct(x0 / w)};top:#{pct(y0 / h)};width:#{pct((x1 - x0) / w)};height:#{pct((y1 - y0) / h)}"
  end

  @doc "Formats a fraction as a CSS percentage."
  def pct(f), do: :erlang.float_to_binary(f * 100.0, decimals: 3) <> "%"
end
