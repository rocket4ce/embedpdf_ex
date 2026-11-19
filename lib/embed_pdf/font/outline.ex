defmodule EmbedPdf.Font.Outline do
  @moduledoc """
  Glyph outline helpers. An outline is a list of `{:move, x, y}`,
  `{:line, x, y}`, `{:curve, x1, y1, x2, y2, x, y}` and `:close`.
  """

  @type cmd ::
          {:move, number(), number()}
          | {:line, number(), number()}
          | {:curve, number(), number(), number(), number(), number(), number()}
          | :close

  @doc "Applies an affine matrix `[a, b, c, d, e, f]` to every point."
  @spec transform([cmd()], [number()]) :: [cmd()]
  def transform(cmds, [a, b, c, d, e, f]) do
    Enum.map(cmds, fn
      {:move, x, y} ->
        {:move, a * x + c * y + e, b * x + d * y + f}

      {:line, x, y} ->
        {:line, a * x + c * y + e, b * x + d * y + f}

      {:curve, x1, y1, x2, y2, x, y} ->
        {:curve, a * x1 + c * y1 + e, b * x1 + d * y1 + f, a * x2 + c * y2 + e,
         b * x2 + d * y2 + f, a * x + c * y + e, b * x + d * y + f}

      :close ->
        :close
    end)
  end

  @doc "Scales every point by `s` (same as `transform(cmds, [s, 0, 0, s, 0, 0])`)."
  @spec scale([cmd()], number()) :: [cmd()]
  def scale(cmds, s), do: transform(cmds, [s, 0, 0, s, 0, 0])

  @doc "Translates every point."
  @spec translate([cmd()], number(), number()) :: [cmd()]
  def translate(cmds, dx, dy), do: transform(cmds, [1, 0, 0, 1, dx, dy])

  @doc "Bounding box `{x0, y0, x1, y1}` of the control points, or nil when empty."
  @spec bbox([cmd()]) :: {number(), number(), number(), number()} | nil
  def bbox(cmds) do
    cmds
    |> Enum.flat_map(fn
      {:move, x, y} -> [{x, y}]
      {:line, x, y} -> [{x, y}]
      {:curve, x1, y1, x2, y2, x, y} -> [{x1, y1}, {x2, y2}, {x, y}]
      :close -> []
    end)
    |> case do
      [] ->
        nil

      [{x, y} | rest] ->
        Enum.reduce(rest, {x, y, x, y}, fn {px, py}, {x0, y0, x1, y1} ->
          {min(x0, px), min(y0, py), max(x1, px), max(y1, py)}
        end)
    end
  end

  @doc "Formats an outline as SVG path data (with `precision` decimals)."
  @spec to_svg_path([cmd()], non_neg_integer()) :: String.t()
  def to_svg_path(cmds, precision \\ 4) do
    f = fn v -> :erlang.float_to_binary(v / 1, decimals: precision) |> trim() end

    cmds
    |> Enum.map(fn
      {:move, x, y} ->
        ["M", f.(x), " ", f.(y)]

      {:line, x, y} ->
        ["L", f.(x), " ", f.(y)]

      {:curve, a, b, c, d, x, y} ->
        ["C", f.(a), " ", f.(b), " ", f.(c), " ", f.(d), " ", f.(x), " ", f.(y)]

      :close ->
        "Z"
    end)
    |> IO.iodata_to_binary()
  end

  defp trim(s) do
    if String.contains?(s, ".") do
      s
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
      |> then(&if(&1 == "-0", do: "0", else: &1))
    else
      s
    end
  end
end
