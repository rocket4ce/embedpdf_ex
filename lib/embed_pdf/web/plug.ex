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

  Every response forbids content sniffing. Page images and the print view
  carry a Content-Security-Policy without script sources, and attachments
  are only ever offered as downloads, so nothing a PDF contains can run
  on the host application's origin.
  """

  @behaviour Plug
  import Plug.Conn

  alias EmbedPdf.{Limits, Store}

  @gif <<"GIF89a", 1::little-16, 1::little-16, 0x80, 0, 0, 0, 0, 0, 255, 255, 255, "!", 0xF9, 4,
         1, 0, 0, 0, 0, ",", 0::little-16, 0::little-16, 1::little-16, 1::little-16, 0, 2, 2, "D",
         1, 0, ";">>

  @impl true
  def init(opts), do: opts

  # ids are url-safe base64 (or the host's own, of the same alphabet)
  @id ~r/\A[A-Za-z0-9_-]{1,128}\z/

  @svg_csp "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; sandbox"
  @print_csp "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"

  # attachment types a browser could run or render as a document
  @active_types ~w(text/html application/xhtml+xml image/svg+xml text/xml application/xml
                   text/javascript application/javascript application/x-javascript text/css)

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn =
      conn
      |> fetch_query_params()
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")

    route(conn, conn.path_info)
  rescue
    Plug.Conn.InvalidQueryError -> not_found(conn)
  end

  def call(conn, _opts), do: conn |> send_resp(405, "") |> halt()

  # the router forwards here; path_info is relative to the mount point
  defp route(conn, ["d", doc, rev, "p", file]) do
    with {:ok, n} <- parse_page(file, ".svg"),
         %Store.Entry{} = entry <- fetch(doc),
         {:ok, rev} <- revision(rev, entry),
         true <- n < EmbedPdf.page_count(entry.doc) do
      rot = rotation(conn.params["r"])
      forms? = conn.params["f"] != "0"

      opts =
        [rotation: rot] ++ if(forms?, do: [], else: [skip_annotations: widget_ids(entry.doc, n)])

      gzip? = accepts_gzip?(conn)

      body =
        Store.cached(doc, {:svg, rev, n, rot, forms?, gzip?}, fn ->
          svg =
            Store.cached(doc, {:svg, rev, n, rot, forms?}, fn -> page_svg(entry.doc, n, opts) end)

          if gzip?, do: :zlib.gzip(svg), else: svg
        end)

      notify(conn.params["v"], {:page_loaded, n})

      conn
      |> put_resp_content_type("image/svg+xml")
      |> put_resp_header("content-security-policy", @svg_csp)
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> put_resp_header("vary", "accept-encoding")
      |> then(&if(gzip?, do: put_resp_header(&1, "content-encoding", "gzip"), else: &1))
      |> send_resp(200, body)
      |> halt()
    else
      _ -> not_found(conn)
    end
  end

  defp route(conn, ["d", doc, "download"]) do
    case fetch(doc) do
      %Store.Entry{} = entry ->
        flatten? = conn.params["flatten"] == "1"
        disposition = if conn.params["inline"] == "1", do: "inline", else: "attachment"

        case Limits.run(fn -> EmbedPdf.Output.bytes(entry, flatten: flatten?) end) do
          {:ok, bytes} ->
            conn
            |> put_resp_content_type("application/pdf")
            |> put_resp_header("content-disposition", disposition(disposition, entry.name))
            |> put_resp_header("content-security-policy", "sandbox")
            |> put_resp_header("cache-control", "no-store")
            |> send_resp(200, bytes)
            |> halt()

          {:error, _} ->
            too_complex(conn)
        end

      nil ->
        not_found(conn)
    end
  end

  defp route(conn, ["d", doc, "attachment", id]) do
    with %Store.Entry{} = entry <- fetch(doc),
         {id, ""} <- Integer.parse(id),
         {:ok, {attachment, data}} when is_map(attachment) and is_binary(data) <-
           Limits.run(fn ->
             {Enum.find(EmbedPdf.Attachments.list(entry.doc), &(&1.id == id)),
              EmbedPdf.Attachments.data(entry.doc, id)}
           end) do
      conn
      |> put_resp_content_type(attachment_type(attachment[:mime]), nil)
      |> put_resp_header("content-disposition", disposition("attachment", attachment.name))
      |> put_resp_header("content-security-policy", "sandbox")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, data)
      |> halt()
    else
      _ -> not_found(conn)
    end
  end

  defp route(conn, ["d", doc, rev, "print"]) do
    with %Store.Entry{} = entry <- fetch(doc),
         {:ok, rev} <- revision(rev, entry) do
      count = EmbedPdf.page_count(entry.doc)
      pages = parse_ranges(conn.params["pages"], count)
      rot = rotation(conn.params["r"])
      html = EmbedPdf.Web.Print.html(entry, doc, rev, pages, rot, base_path(conn))

      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("content-security-policy", @print_csp)
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, html)
      |> halt()
    else
      _ -> not_found(conn)
    end
  end

  defp route(conn, ["d", doc, rev, "snapshot", file]) do
    with {:ok, n} <- parse_page(file, ".svg"),
         %Store.Entry{} = entry <- fetch(doc),
         {:ok, _rev} <- revision(rev, entry),
         true <- n < EmbedPdf.page_count(entry.doc),
         [x0, y0, x1, y1] <- Enum.map(~w(x0 y0 x1 y1), &float(conn.params[&1])),
         true <- Enum.all?([x0, y0, x1, y1], &(is_float(&1) and abs(&1) < 1.0e6)),
         true <- x1 > x0 and y1 > y0 do
      svg =
        page_svg(entry.doc, n, rotation: rotation(conn.params["r"]), viewbox: {x0, y0, x1, y1})

      conn
      |> put_resp_content_type("image/svg+xml")
      |> put_resp_header("content-security-policy", @svg_csp)
      |> put_resp_header("cache-control", "no-store")
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

    # both end up inside the stylesheet, so they must be plain tokens
    if id?(viewer) and id?(nonce) do
      conn
      |> put_resp_content_type("text/css")
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> send_resp(200, EmbedPdf.Live.Probe.css(base_path(conn), viewer, nonce))
      |> halt()
    else
      not_found(conn)
    end
  end

  defp route(conn, ["probe"]) do
    viewer = conn.params["v"]
    w = int(conn.params["w"])
    h = int(conn.params["h"])

    cond do
      w in 1..20_000 -> notify(viewer, {:probe, :width, w})
      h in 1..20_000 -> notify(viewer, {:probe, :height, h})
      true -> :ok
    end

    gif(conn)
  end

  defp route(conn, ["seen", viewer, count, file]) do
    with {count, ""} <- Integer.parse(count),
         true <- count >= 0 and count <= 20_000,
         nonce = String.trim_trailing(file, ".css"),
         true <- id?(viewer) and id?(nonce) do
      conn
      |> put_resp_content_type("text/css")
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> send_resp(
        200,
        EmbedPdf.Live.Probe.seen_css(base_path(conn), viewer, count, nonce)
      )
      |> halt()
    else
      _ -> not_found(conn)
    end
  end

  defp route(conn, ["seen"]) do
    p = conn.params

    with page when is_integer(page) and page >= 0 <- int(p["p"]),
         nonce when is_integer(nonce) <- int(p["n"]) do
      notify(p["v"], {:seen, page, nonce})
    end

    gif(conn)
  end

  defp route(conn, ["pointer"]) do
    p = conn.params

    with page when is_integer(page) and page >= 0 <- int(p["p"]),
         x when is_number(x) <- float(p["pt.x"]),
         y when is_number(y) <- float(p["pt.y"]),
         w when is_number(w) and w > 0 <- float(p["w"]),
         h when is_number(h) and h > 0 <- float(p["h"]) do
      kind = if is_binary(p["k"]) and id?(p["k"]), do: p["k"]
      notify(p["v"], {:pointer, page, unit(x / w), unit(y / h), kind})
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

  defp accepts_gzip?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.any?(&String.contains?(&1, "gzip"))
  end

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
    if is_binary(viewer) and id?(viewer) do
      Phoenix.PubSub.broadcast(
        EmbedPdf.PubSub,
        "embed_pdf:viewer:" <> viewer,
        {:embed_pdf, message}
      )
    end

    :ok
  end

  defp id?(value), do: is_binary(value) and Regex.match?(@id, value)

  defp fetch(doc), do: if(id?(doc), do: Store.get(doc))

  # the revision in a URL only keeps caches apart; it must be one this
  # document has had, so requests cannot fill the render cache with new keys
  defp revision(rev, %Store.Entry{revision: current}) do
    case Integer.parse(rev) do
      {n, ""} when n >= 0 and n <= current -> {:ok, n}
      _ -> :error
    end
  end

  defp unit(v), do: v |> max(0.0) |> min(1.0)

  defp attachment_type(mime) do
    mime = is_binary(mime) && String.downcase(String.trim(mime))

    if (mime && Regex.match?(~r{\A[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*\z}, mime)) and
         mime not in @active_types,
       do: mime,
       else: "application/octet-stream"
  end

  defp gif(conn) do
    conn
    |> put_resp_content_type("image/gif")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, @gif)
    |> halt()
  end

  defp not_found(conn), do: conn |> send_resp(404, "not found") |> halt()
  defp too_complex(conn), do: conn |> send_resp(422, "document too complex") |> halt()

  # A page drawn within EmbedPdf.Limits; one that asks for too much comes
  # out blank instead of taking the server's memory or time.
  defp page_svg(doc, n, opts) do
    case Limits.run(fn ->
           doc |> EmbedPdf.Render.SVG.render_page(n, opts) |> IO.iodata_to_binary()
         end) do
      {:ok, svg} ->
        svg

      {:error, _} ->
        {w, h} = Limits.run_or(fn -> EmbedPdf.page_size(doc, n) end, {612.0, 792.0})

        ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{w} #{h}" width="#{w}" height="#{h}"><rect width="100%" height="100%" fill="#fff"/></svg>)
    end
  end

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

  defp int(v) when is_binary(v) and byte_size(v) <= 12 do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp int(_), do: nil

  defp float(nil), do: nil

  # Float.parse raises on some out-of-range inputs, hence the length limit
  defp float(v) when is_binary(v) and byte_size(v) <= 24 do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp float(_), do: nil

  # an ASCII fallback plus the real name in RFC 5987 form; nothing from the
  # name can end the header or the quoted string
  defp disposition(kind, name) do
    name = if is_binary(name) and String.valid?(name), do: name, else: "document.pdf"
    name = name |> String.replace(~r/[\x00-\x1f\x7f\/\\]/u, "_") |> String.slice(0, 200)
    name = if String.trim(name) == "", do: "document.pdf", else: name
    ascii = String.replace(name, ~r/[^A-Za-z0-9 ._()-]/u, "_")

    ~s(#{kind}; filename="#{ascii}"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
  end

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
          # clamp before expanding: "1-999999999999" must not build that list
          with {x, ""} <- Integer.parse(String.trim(a)),
               {y, ""} <- Integer.parse(String.trim(b)) do
            Enum.to_list(max(x - 1, 0)..min(y - 1, count - 1)//1)
          else
            _ -> []
          end
      end
    end)
    |> Enum.filter(&(&1 >= 0 and &1 < count))
    |> Enum.uniq()
  end
end
