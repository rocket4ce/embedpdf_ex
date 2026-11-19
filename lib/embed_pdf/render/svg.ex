defmodule EmbedPdf.Render.SVG do
  @moduledoc """
  Renders pages to SVG. (Interim version: text with system fonts and plain
  paths; the full renderer replaces it.)
  """

  alias EmbedPdf.Font
  alias EmbedPdf.PDF.{Document, Page}
  alias EmbedPdf.Render.{Interpreter, Matrix}

  @flip [1.0, 0.0, 0.0, -1.0, 0.0, 0.0]

  @doc "Renders page `index` to a standalone SVG document."
  @spec render_page(Document.t(), non_neg_integer(), keyword()) :: iodata()
  def render_page(doc, index, opts \\ []) do
    page = Document.page(doc, index)
    rot = Keyword.get(opts, :rotation, 0)
    {w, h} = Page.display_size(page)
    {w, h} = if rem(div(rot, 90), 2) == 1, do: {h, w}, else: {w, h}
    view = Page.view_matrix(page, rot)

    body =
      doc
      |> Interpreter.run_page(page, &draw(&1, &2, view), [])
      |> Enum.reverse()

    {vx, vy, vw, vh} =
      case opts[:viewbox] do
        {x0, y0, x1, y1} -> {x0, y0, x1 - x0, y1 - y0}
        nil -> {0, 0, w, h}
      end

    [
      ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="#{num(vx)} #{num(vy)} #{num(vw)} #{num(vh)}" width="#{num(vw)}" height="#{num(vh)}">),
      ~s(<rect x="0" y="0" width="#{num(w)}" height="#{num(h)}" fill="#fff"/>),
      body,
      "</svg>"
    ]
  end

  defp draw(
         {:glyph, %{font: font, glyph: {_, _, uni, _, _} = glyph, trm: trm, gs: gs}},
         acc,
         view
       ) do
    outline =
      if gs.render_mode in [3, 7] or font.type == "Type3",
        do: nil,
        else: Font.glyph_outline(font, glyph)

    cond do
      is_list(outline) and outline != [] ->
        m = Matrix.multiply(trm, view)
        opacity = if gs.fill_alpha < 1, do: ~s( fill-opacity="#{num(gs.fill_alpha)}"), else: ""

        [
          [
            "<path transform=\"matrix(",
            mat(m),
            ")\" d=\"",
            EmbedPdf.Font.Outline.to_svg_path(outline, 2),
            "\" fill=\"",
            color(gs.fill),
            "\"",
            opacity,
            "/>"
          ]
          | acc
        ]

      gs.render_mode in [3, 7] or font.type == "Type3" or String.trim(uni) == "" or
          is_list(outline) ->
        acc

      true ->
        css = Font.css(font)
        m = @flip |> Matrix.multiply(trm) |> Matrix.multiply(view)

        [
          [
            "<text transform=\"matrix(" <>
              mat(m) <>
              ")\" font-size=\"1\" font-family=\"" <>
              css.family <>
              "\" font-weight=\"" <>
              css.weight <>
              "\" font-style=\"" <> css.style <> "\" fill=\"" <> color(gs.fill) <> "\"",
            if(gs.fill_alpha < 1, do: ~s( fill-opacity="#{num(gs.fill_alpha)}"), else: ""),
            ">",
            escape(uni),
            "</text>"
          ]
          | acc
        ]
    end
  end

  defp draw({:path, %{path: cmds, fill: fill, stroke: stroke?, gs: gs}}, acc, view) do
    m = Matrix.multiply(gs.ctm, view)

    fill_attr =
      case fill do
        nil -> ~s( fill="none")
        :evenodd -> ~s( fill="#{color(gs.fill)}" fill-rule="evenodd")
        :nonzero -> ~s( fill="#{color(gs.fill)}")
      end

    stroke_attr =
      if stroke? do
        ~s( stroke="#{color(gs.stroke)}" stroke-width="#{num(max(gs.line_width, 0.01))}")
      else
        ""
      end

    [
      [
        "<path transform=\"matrix(",
        mat(m),
        ")\" d=\"",
        path_d(cmds),
        "\"",
        fill_attr,
        stroke_attr,
        "/>"
      ]
      | acc
    ]
  end

  defp draw(_, acc, _), do: acc

  defp path_d(cmds) do
    Enum.map(cmds, fn
      {:m, x, y} -> ["M", num(x), " ", num(y)]
      {:l, x, y} -> ["L", num(x), " ", num(y)]
      {:c, a, b, c, d, e, f} -> ["C", Enum.map_join([a, b, c, d, e, f], " ", &num/1)]
      {:re, x, y, w, h} -> ["M", num(x), " ", num(y), "h", num(w), "v", num(h), "h", num(-w), "Z"]
      :h -> "Z"
    end)
  end

  defp color({r, g, b}), do: EmbedPdf.Render.ColorSpace.hex({r, g, b})
  defp mat(m), do: Enum.map_join(m, " ", &num/1)

  defp escape(s),
    do:
      s
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp num(f) when is_integer(f), do: Integer.to_string(f)
  defp num(f), do: :erlang.float_to_binary(f / 1, decimals: 3)
end
