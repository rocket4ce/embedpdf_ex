defmodule EmbedPdf.PDF.Page do
  @moduledoc """
  A page with its inherited attributes resolved.

  `box` is the visible area (the CropBox clipped to the MediaBox) as
  `{x0, y0, x1, y1}` in PDF user space; `width`/`height` are its size before
  `rotate` (0, 90, 180 or 270, clockwise) is applied.
  """

  alias EmbedPdf.PDF.Document

  defstruct [
    :index,
    :ref,
    :dict,
    :media_box,
    :box,
    :rotate,
    :resources,
    :width,
    :height,
    user_unit: 1.0
  ]

  @type rect :: {number(), number(), number(), number()}
  @type t :: %__MODULE__{
          index: non_neg_integer(),
          ref: {:ref, integer(), integer()} | nil,
          dict: map(),
          media_box: rect(),
          box: rect(),
          rotate: 0 | 90 | 180 | 270,
          resources: map(),
          width: float(),
          height: float(),
          user_unit: float()
        }

  @letter {0, 0, 612, 792}

  @doc false
  def new(doc, index, ref, dict, inherited) do
    get = fn key -> Document.resolve(doc, Map.get(dict, key, inherited[key])) end

    media = normalize_rect(get.("MediaBox"), doc) || @letter
    crop = normalize_rect(get.("CropBox"), doc) || media
    box = intersect(crop, media) || media

    rotate =
      case get.("Rotate") do
        r when is_number(r) -> r |> trunc() |> Integer.mod(360) |> div(90) |> Kernel.*(90)
        _ -> 0
      end

    resources =
      case get.("Resources") do
        m when is_map(m) -> m
        _ -> %{}
      end

    {x0, y0, x1, y1} = box

    user_unit =
      case Document.resolve(doc, dict["UserUnit"]) do
        u when is_number(u) and u > 0 -> u / 1
        _ -> 1.0
      end

    %__MODULE__{
      index: index,
      ref: ref,
      dict: dict,
      media_box: media,
      box: box,
      rotate: rotate,
      resources: resources,
      width: (x1 - x0) / 1,
      height: (y1 - y0) / 1,
      user_unit: user_unit
    }
  end

  @doc "Normalizes a rectangle array into `{x0, y0, x1, y1}` with x0 < x1 and y0 < y1."
  @spec normalize_rect(term(), Document.t() | nil) :: rect() | nil
  def normalize_rect(list, doc \\ nil)

  def normalize_rect([a, b, c, d], doc) do
    [a, b, c, d] =
      if doc, do: Enum.map([a, b, c, d], &Document.resolve(doc, &1)), else: [a, b, c, d]

    if Enum.all?([a, b, c, d], &is_number/1) and a != c and b != d,
      do: {min(a, c), min(b, d), max(a, c), max(b, d)},
      else: nil
  end

  def normalize_rect(_, _), do: nil

  defp intersect({a0, b0, a1, b1}, {c0, d0, c1, d1}) do
    x0 = max(a0, c0)
    y0 = max(b0, d0)
    x1 = min(a1, c1)
    y1 = min(b1, d1)
    if x1 > x0 and y1 > y0, do: {x0, y0, x1, y1}, else: nil
  end

  @doc "Size of the page as displayed (after rotation), in points."
  @spec display_size(t()) :: {float(), float()}
  def display_size(%__MODULE__{rotate: r, width: w, height: h}) when r in [90, 270], do: {h, w}
  def display_size(%__MODULE__{width: w, height: h}), do: {w, h}

  @doc """
  The matrix `[a, b, c, d, e, f]` mapping PDF user space to the displayed
  page with origin at the top-left, y down, in points, for an extra
  `view_rotation` (degrees clockwise) applied on top of the page's own.
  """
  @spec view_matrix(t(), integer()) :: [float()]
  def view_matrix(%__MODULE__{box: {x0, y0, x1, y1}} = page, view_rotation \\ 0) do
    case Integer.mod(page.rotate + view_rotation, 360) do
      0 -> [1.0, 0.0, 0.0, -1.0, -x0 / 1, y1 / 1]
      90 -> [0.0, 1.0, 1.0, 0.0, -y0 / 1, -x0 / 1]
      180 -> [-1.0, 0.0, 0.0, 1.0, x1 / 1, -y0 / 1]
      270 -> [0.0, -1.0, -1.0, 0.0, y1 / 1, x1 / 1]
    end
  end

  @doc "Converts a point in displayed page points (top-left origin) to PDF user space."
  @spec to_user(t(), {number(), number()}, integer()) :: {float(), float()}
  def to_user(page, {x, y}, view_rotation \\ 0) do
    page
    |> view_matrix(view_rotation)
    |> EmbedPdf.Render.Matrix.invert()
    |> EmbedPdf.Render.Matrix.apply(x, y)
  end

  @doc "Converts a point in PDF user space to displayed page points (top-left origin)."
  @spec to_display(t(), {number(), number()}, integer()) :: {float(), float()}
  def to_display(page, {x, y}, view_rotation \\ 0) do
    page |> view_matrix(view_rotation) |> EmbedPdf.Render.Matrix.apply(x, y)
  end

  @doc "Converts a user-space rectangle `{x0, y0, x1, y1}` to a displayed one."
  @spec rect_to_display(t(), rect(), integer()) :: rect()
  def rect_to_display(page, rect, view_rotation \\ 0),
    do: EmbedPdf.Render.Matrix.transform_rect(view_matrix(page, view_rotation), rect)

  @doc "Converts a displayed rectangle to a user-space one."
  @spec rect_to_user(t(), rect(), integer()) :: rect()
  def rect_to_user(page, rect, view_rotation \\ 0),
    do:
      EmbedPdf.Render.Matrix.transform_rect(
        EmbedPdf.Render.Matrix.invert(view_matrix(page, view_rotation)),
        rect
      )
end
