defmodule EmbedPdf.Web.Plug do
  @moduledoc """
  HTTP endpoints of the viewer, mounted by `EmbedPdf.Router.embed_pdf_routes/2`
  (default prefix `/embedpdf`):

    * `GET d/:doc/:rev/p/:n.svg` – a page as SVG (`r` rotation, `v` viewer, `f=0` hides form widgets)
    * `GET d/:doc/download` – the PDF with every change (`flatten=1` bakes annotations)
    * `GET d/:doc/:rev/print` – print-ready HTML of the pages (`pages=1-3,5`)
    * `GET d/:doc/attachment/:id` – an attached file
    * `GET d/:doc/:rev/snapshot/:n.svg` – a region of a page (`x0 y0 x1 y1 r`)
    * `GET probe/:viewer/:nonce.css` and `GET probe` – the container-size probe
    * `GET pointer` – a click on a page, sent by a plain HTML form (`<input type=image>`)

  Documents are addressed by unguessable ids from `EmbedPdf.Store`; viewer
  ids are unguessable too, so these URLs carry their own authorization.
  """

  @behaviour Plug
  import Plug.Conn

  alias EmbedPdf.Store

  @gif <<"GIF89a", 1::little-16, 1::little-16, 0x80, 0, 0, 0, 0, 0, 255, 255, 255, "!", 0xF9, 4,
         1, 0, 0, 0, 0, ",", 0::little-16, 0::little-16, 1::little-16, 1::little-16, 0, 2, 2, "D",
         1, 0, ";">>

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn = fetch_query_params(conn)
    route(conn, conn.path_info)
  end

  def call(conn, _opts), do: conn |> send_resp(405, "") |> halt()

  # the router forwards here; path_info is relative to the mount point
  defp route(conn, ["d", doc, rev, "p", file]) do
    with {:ok, n} <- parse_page(file, ".svg"),
         %Store.Entry{} = entry <- Store.get(doc),
         true <- n < EmbedPdf.page_count(entry.doc) do
      rot = rotation(conn.params["r"])
      forms? = conn.params["f"] != "0"

      opts =
        [rotation: rot] ++ if(forms?, do: [], else: [skip_annotations: widget_ids(entry.doc, n)])

      svg =
        Store.cached(doc, {:svg, rev, n, rot, forms?}, fn ->
          entry.doc |> EmbedPdf.Render.SVG.render_page(n, opts) |> IO.iodata_to_binary()
        end)

      if viewer = conn.params["v"], do: notify(viewer, {:page_loaded, n})

      conn
      |> put_resp_content_type("image/svg+xml")
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> send_resp(200, svg)
      |> halt()
    else
      _ -> not_found(conn)
    end
  end

  defp route(conn, ["d", doc, "download"]) do
    case Store.get(doc) do
      %Store.Entry{} = entry ->
        doc_value =
          if conn.params["flatten"] == "1" and Code.ensure_loaded?(EmbedPdf.Writer) and
               function_exported?(EmbedPdf.Writer, :flatten_annotations, 2),
             do: EmbedPdf.Writer.flatten_annotations(entry.doc, :all),
             else: entry.doc

        bytes =
          if Code.ensure_loaded?(EmbedPdf.Writer) and
               function_exported?(EmbedPdf.Writer, :save, 2),
             do: EmbedPdf.Writer.save(doc_value, []),
             else: EmbedPdf.save(doc_value)

        disposition = if conn.params["inline"] == "1", do: "inline", else: "attachment"

        conn
        |> put_resp_content_type("application/pdf")
        |> put_resp_header(
          "content-disposition",
          ~s(#{disposition}; filename="#{safe_name(entry.name)}")
        )
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, bytes)
        |> halt()

      nil ->
        not_found(conn)
    end
  end

  defp route(conn, ["d", doc, "attachment", id]) do
    with %Store.Entry{} = entry <- Store.get(doc),
         {id, ""} <- Integer.parse(id),
         attachment when is_map(attachment) <-
           Enum.find(EmbedPdf.Attachments.list(entry.doc), &(&1.id == id)),
         data when is_binary(data) <- EmbedPdf.Attachments.data(entry.doc, id) do
      conn
      |> put_resp_content_type(attachment[:mime] || "application/octet-stream")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{safe_name(attachment.name)}")
      )
      |> send_resp(200, data)
      |> halt()
    else
      _ -> not_found(conn)
    end
  end

  defp route(conn, ["d", doc, rev, "print"]) do
    case Store.get(doc) do
      %Store.Entry{} = entry ->
        count = EmbedPdf.page_count(entry.doc)
        pages = parse_ranges(conn.params["pages"], count)
        rot = rotation(conn.params["r"])
        html = EmbedPdf.Web.Print.html(entry, doc, rev, pages, rot, base_path(conn))

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)
        |> halt()

      nil ->
        not_found(conn)
    end
  end

  defp route(conn, ["d", doc, _rev, "snapshot", file]) do
    with {:ok, n} <- parse_page(file, ".svg"),
         %Store.Entry{} = entry <- Store.get(doc),
         [x0, y0, x1, y1] <- Enum.map(~w(x0 y0 x1 y1), &float(conn.params[&1])),
         true <- x1 > x0 and y1 > y0 do
      svg =
        EmbedPdf.Render.SVG.render_page(entry.doc, n,
          rotation: rotation(conn.params["r"]),
          viewbox: {x0, y0, x1, y1}
        )

      conn
      |> put_resp_content_type("image/svg+xml")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="snapshot-page-#{n + 1}.svg")
      )
      |> send_resp(200, svg)
      |> halt()
    else
      _ -> not_found(conn)
    end
  end

  defp route(conn, ["probe", viewer, file]) do
    nonce = String.trim_trailing(file, ".css")

    conn
    |> put_resp_content_type("text/css")
    |> put_resp_header("cache-control", "private, max-age=86400")
    |> send_resp(200, EmbedPdf.Live.Probe.css(base_path(conn), viewer, nonce))
    |> halt()
  end

  defp route(conn, ["probe"]) do
    %{"v" => viewer} = conn.params

    cond do
      w = int(conn.params["w"]) -> notify(viewer, {:probe, :width, w})
      h = int(conn.params["h"]) -> notify(viewer, {:probe, :height, h})
      true -> :ok
    end

    gif(conn)
  rescue
    _ -> gif(conn)
  end

  defp route(conn, ["seen", viewer, count, file]) do
    with {count, ""} <- Integer.parse(count),
         true <- count >= 0 and count <= 20_000 do
      conn
      |> put_resp_content_type("text/css")
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> send_resp(
        200,
        EmbedPdf.Live.Probe.seen_css(
          base_path(conn),
          viewer,
          count,
          String.trim_trailing(file, ".css")
        )
      )
      |> halt()
    else
      _ -> not_found(conn)
    end
  end

  defp route(conn, ["seen"]) do
    p = conn.params

    with viewer when is_binary(viewer) <- p["v"],
         page when is_integer(page) <- int(p["p"]),
         nonce when is_integer(nonce) <- int(p["n"]) do
      notify(viewer, {:seen, page, nonce})
    end

    gif(conn)
  end

  defp route(conn, ["pointer"]) do
    p = conn.params

    with viewer when is_binary(viewer) <- p["v"],
         page when is_integer(page) <- int(p["p"]),
         x when is_number(x) <- float(p["pt.x"]),
         y when is_number(y) <- float(p["pt.y"]),
         w when is_number(w) and w > 0 <- float(p["w"]),
         h when is_number(h) and h > 0 <- float(p["h"]) do
      notify(viewer, {:pointer, page, x / w, y / h, p["k"]})
    end

    # 204 cancels the iframe navigation, so no history entry is created
    conn |> send_resp(204, "") |> halt()
  end

  defp route(conn, ["assets", "viewer.css"]) do
    conn
    |> put_resp_content_type("text/css")
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> send_resp(200, EmbedPdf.Live.CSS.css())
    |> halt()
  end

  defp route(conn, _), do: not_found(conn)

  # ---------------------------------------------------------------- helpers

  defp widget_ids(doc, n) do
    alias EmbedPdf.PDF.Document
    page = Document.page(doc, n)

    (Document.resolve(doc, page.dict["Annots"]) || [])
    |> Enum.flat_map(fn ref ->
      case {ref, Document.resolve(doc, ref)} do
        {{:ref, num, _}, %{"Subtype" => "Widget"}} -> [num]
        _ -> []
      end
    end)
  end

  defp notify(viewer, message) do
    Phoenix.PubSub.broadcast(
      EmbedPdf.PubSub,
      "embed_pdf:viewer:" <> viewer,
      {:embed_pdf, message}
    )
  end

  defp gif(conn) do
    conn
    |> put_resp_content_type("image/gif")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, @gif)
    |> halt()
  end

  defp not_found(conn), do: conn |> send_resp(404, "not found") |> halt()

  defp parse_page(file, ext) do
    with true <- String.ends_with?(file, ext),
         {n, ""} <- Integer.parse(String.trim_trailing(file, ext)),
         true <- n >= 0 do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp rotation(value) do
    case int(value) do
      r when r in [0, 90, 180, 270] -> r
      _ -> 0
    end
  end

  defp int(nil), do: nil

  defp int(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp float(nil), do: nil

  defp float(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp safe_name(name), do: (name || "document.pdf") |> String.replace(~r/["\\\r\n]/, "_")

  defp base_path(conn) do
    "/" <> Enum.join(conn.script_name, "/")
  end

  @doc false
  def parse_ranges(nil, count), do: Enum.to_list(0..(count - 1)//1)
  def parse_ranges("", count), do: parse_ranges(nil, count)

  def parse_ranges(spec, count) do
    spec
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case String.split(String.trim(part), "-", parts: 2) do
        [a] ->
          with {n, ""} <- Integer.parse(a), do: [n - 1], else: (_ -> [])

        [a, b] ->
          with {x, ""} <- Integer.parse(String.trim(a)),
               {y, ""} <- Integer.parse(String.trim(b)) do
            Enum.to_list((x - 1)..(y - 1)//1)
          else
            _ -> []
          end
      end
    end)
    |> Enum.filter(&(&1 >= 0 and &1 < count))
    |> Enum.uniq()
  end
end
