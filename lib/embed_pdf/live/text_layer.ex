defmodule EmbedPdf.Live.TextLayer do
  @moduledoc """
  The invisible, selectable text over each page image. Lines are placed in
  percentages of the page box and sized from the CSS variable
  `--epdf-scale`, so zooming never re-sends them; each line is stretched
  with `scaleX` to the width the PDF gives it, using Helvetica metrics to
  predict the browser's own width. Words carry their character range so a
  click tells the server which word it was.
  """

  alias EmbedPdf.Font.{AFM, GlyphList}
  alias EmbedPdf.Live.Layout
  alias EmbedPdf.Text

  @helvetica AFM.get("Helvetica").widths

  @doc "Builds the layer's lines for a page of unrotated size `{w, h}` viewed at `rotation`."
  @spec build(Text.PageText.t(), {number(), number()}, integer()) :: [map()]
  def build(%Text.PageText{lines: lines}, {w, h}, rotation) do
    {rw, rh} = Layout.rotated({w, h}, rotation)

    lines
    |> Enum.reject(&(String.trim(&1.text) == ""))
    |> Enum.map(fn line ->
      {x0, y0, x1, y1} = line.box
      vertical? = abs(line.angle) > 45 and abs(line.angle) < 135
      {box_w, box_h} = if vertical?, do: {y1 - y0, x1 - x0}, else: {x1 - x0, y1 - y0}
      font_size = max(box_h, 1.0)
      est = estimate(line.text) * font_size
      sx = if est > 0, do: box_w / est, else: 1.0
      angle = rotation + if(vertical?, do: round(line.angle / 90) * 90, else: 0)

      origin =
        cond do
          vertical? and line.angle > 0 -> {x1, y0}
          vertical? -> {x0, y1}
          true -> {x0, y0}
        end

      {ox, oy} = Layout.rotate_point(origin, {w, h}, rotation)

      transform =
        if angle == 0,
          do: "scaleX(#{fmt(sx)})",
          else: "rotate(#{angle}deg) scaleX(#{fmt(sx)})"

      %{
        style:
          "left:#{Layout.pct(ox / rw)};top:#{Layout.pct(oy / rh)};font-size:calc(var(--epdf-scale) * #{fmt(font_size)}px);transform:#{transform}",
        words: words(line)
      }
    end)
  end

  # splits a line into {:word, text, from, to} and {:space, text}
  defp words(line) do
    line.text
    |> String.graphemes()
    |> Enum.with_index(line.start)
    |> Enum.chunk_by(fn {g, _} -> String.trim(g) == "" end)
    |> Enum.map(fn [{g, i} | _] = chunk ->
      text = Enum.map_join(chunk, &elem(&1, 0))

      if String.trim(g) == "",
        do: {:space, text},
        else: {:word, text, i, chunk |> List.last() |> elem(1)}
    end)
  end

  defp estimate(text) do
    text
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc ->
      w =
        case GlyphList.to_name(g) do
          nil -> default_width(g)
          name -> Map.get(@helvetica, name) || default_width(g)
        end

      acc + w
    end)
    |> Kernel./(1000)
  end

  defp default_width(g) do
    case String.to_charlist(g) do
      [cp | _] when cp >= 0x2E80 -> 1000
      _ -> 556
    end
  end

  defp fmt(f), do: :erlang.float_to_binary(f / 1, decimals: 4)
end
