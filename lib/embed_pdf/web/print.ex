defmodule EmbedPdf.Web.Print do
  @moduledoc """
  The print view: an HTML page holding one page image per sheet, sized
  with `@page` rules, ready for the browser's print command.
  """

  @doc false
  def html(entry, doc_id, rev, pages, rot, base)
      when is_integer(rev) and rot in [0, 90, 180, 270] do
    esc = &(&1 |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string())
    title = esc.(entry.name)
    doc_id = esc.(doc_id)
    base = esc.(base)

    imgs =
      Enum.map(pages, fn n ->
        {w, h} = entry.doc |> EmbedPdf.page_size(n) |> EmbedPdf.Live.Layout.rotated(rot)
        orientation = if w > h, do: "landscape", else: "portrait"

        ~s(<section class="sheet #{orientation}"><img src="#{base}/d/#{doc_id}/#{rev}/p/#{n}.svg?r=#{rot}" alt="Page #{n + 1}" style="aspect-ratio:#{w}/#{h}"></section>)
      end)

    """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>#{title}</title>
    <style>
    html,body{margin:0;background:#525659;font-family:system-ui,sans-serif}
    .bar{position:sticky;top:0;padding:10px 16px;background:#323639;color:#fff;font-size:14px;display:flex;gap:12px;align-items:center}
    .bar kbd{background:#555;border-radius:4px;padding:1px 6px}
    .sheet{display:flex;justify-content:center;padding:12px 0}
    .sheet img{max-width:min(100%,900px);height:auto;background:#fff;box-shadow:0 2px 8px rgba(0,0,0,.4)}
    @page{margin:0}
    @media print{
      html,body{background:none}
      .bar{display:none}
      .sheet{padding:0;break-after:page;page-break-after:always;height:100vh;align-items:center}
      .sheet:last-child{break-after:auto;page-break-after:auto}
      .sheet img{max-width:100%;max-height:100vh;box-shadow:none}
    }
    </style></head>
    <body><div class="bar"><strong>#{title}</strong><span>#{length(pages)} page(s) ready: press <kbd>Ctrl</kbd>+<kbd>P</kbd> (<kbd>⌘</kbd>+<kbd>P</kbd> on Mac) to print.</span></div>
    #{Enum.join(imgs, "\n")}
    </body></html>
    """
  end
end
