defmodule EmbedPdf.Render.Matrix do
  @moduledoc "2D affine matrices `[a, b, c, d, e, f]` as PDF uses them (row vectors)."

  import Kernel, except: [apply: 3]

  @type t :: [number()]

  @identity [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
  def identity, do: @identity

  @doc "`m1 × m2`: apply m1 first, then m2."
  @spec multiply(t(), t()) :: t()
  def multiply([a1, b1, c1, d1, e1, f1], [a2, b2, c2, d2, e2, f2]) do
    [
      a1 * a2 + b1 * c2,
      a1 * b2 + b1 * d2,
      c1 * a2 + d1 * c2,
      c1 * b2 + d1 * d2,
      e1 * a2 + f1 * c2 + e2,
      e1 * b2 + f1 * d2 + f2
    ]
  end

  @doc "Applies a matrix to a point."
  @spec apply(t(), number(), number()) :: {float(), float()}
  def apply([a, b, c, d, e, f], x, y), do: {a * x + c * y + e, b * x + d * y + f}

  @doc "Applies only the linear part (for vectors)."
  def apply_vector([a, b, c, d, _, _], x, y), do: {a * x + c * y, b * x + d * y}

  @doc "Inverse matrix (identity when singular)."
  @spec invert(t()) :: t()
  def invert([a, b, c, d, e, f]) do
    det = a * d - b * c

    if abs(det) < 1.0e-12 do
      @identity
    else
      [d / det, -b / det, -c / det, a / det, (c * f - d * e) / det, (b * e - a * f) / det]
    end
  end

  def translate(tx, ty), do: [1.0, 0.0, 0.0, 1.0, tx / 1, ty / 1]
  def scale(sx, sy), do: [sx / 1, 0.0, 0.0, sy / 1, 0.0, 0.0]

  @doc "Bounding box `{x0, y0, x1, y1}` of a rectangle transformed by `m`."
  @spec transform_rect(t(), {number(), number(), number(), number()}) ::
          {float(), float(), float(), float()}
  def transform_rect(m, {x0, y0, x1, y1}) do
    pts = [apply(m, x0, y0), apply(m, x1, y0), apply(m, x0, y1), apply(m, x1, y1)]
    xs = Enum.map(pts, &elem(&1, 0))
    ys = Enum.map(pts, &elem(&1, 1))
    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  @doc "The geometric mean scale of a matrix (for line widths)."
  def scale_factor([a, b, c, d, _, _]), do: :math.sqrt(abs(a * d - b * c))

  @doc "Coerces a PDF array into a matrix of floats (identity when malformed)."
  def from_pdf([_, _, _, _, _, _] = m) do
    if Enum.all?(m, &is_number/1), do: Enum.map(m, &(&1 / 1)), else: @identity
  end

  def from_pdf(_), do: @identity
end
