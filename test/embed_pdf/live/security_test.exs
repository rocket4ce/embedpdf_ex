defmodule EmbedPdf.Live.SecurityTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import EmbedPdf.TestHelpers

  alias EmbedPdf.{Annotations, Store}

  @endpoint EmbedPdf.TestEndpoint

  defp a(view), do: :sys.get_state(view.pid).socket.assigns
  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()
  defp segment(text), do: URI.encode(text, &URI.char_unreserved?/1)

  defp mount_viewer(file, session) do
    {:ok, view, _html} =
      live_isolated(build_conn(), EmbedPdf.Live.Viewer,
        session: Map.merge(%{"path" => fixture(file)}, session)
      )

    view
  end

  describe "opening" do
    test "bytes are never taken as a path to read" do
      path = fixture("ebook.pdf")
      assert {:error, :not_a_pdf} = EmbedPdf.open(path)
      assert {:error, :not_a_pdf} = EmbedPdf.open("/etc/passwd")
      assert {:ok, _} = EmbedPdf.open_file(path)
      assert {:error, :enoent} = EmbedPdf.open_file(path <> ".missing")
    end

    test "an uploaded file holding a server path does not open that file" do
      {:ok, view, _} = live_isolated(build_conn(), EmbedPdf.Live.Viewer, session: %{})

      upload =
        file_input(view, "form[phx-change=validate_upload]", :pdf, [
          %{name: "x.pdf", content: fixture("ebook.pdf"), type: "application/pdf"}
        ])

      render_upload(upload, "x.pdf")
      assert a(view).doc == nil
      assert a(view).status == :error
    end
  end

  describe "http endpoints" do
    setup do
      doc = open!("ebook.pdf")
      %{id: Store.put(doc, name: "re\"port\r\nSet-Cookie: x=1 é.pdf"), doc: doc}
    end

    test "nothing from the URL reaches the print page", %{id: id} do
      payload = segment("\"><script>alert(1)</script>")
      conn = get(build_conn(), "/embedpdf/d/#{id}/#{payload}/print")
      assert conn.status == 404

      conn = get(build_conn(), "/embedpdf/d/#{id}/0/print")
      assert conn.status == 200
      refute conn.resp_body =~ "<script"
      assert header(conn, "content-security-policy") =~ "default-src 'none'"
      assert header(conn, "x-content-type-options") == "nosniff"
      # the file name is escaped in the markup
      assert conn.resp_body =~ "re&quot;port"
    end

    test "a huge page range is clamped to the document", %{id: id} do
      assert EmbedPdf.Web.Plug.parse_ranges("1-999999999999", 4) == [0, 1, 2, 3]
      assert EmbedPdf.Web.Plug.parse_ranges("0-2,9-99999999", 4) == [0, 1]
      conn = get(build_conn(), "/embedpdf/d/#{id}/0/print?pages=1-999999999999")
      assert conn.status == 200
      assert length(String.split(conn.resp_body, "<section")) == 5
    end

    test "page images forbid scripts and only exist for real revisions", %{id: id} do
      conn = get(build_conn(), "/embedpdf/d/#{id}/0/p/0.svg")
      assert conn.status == 200
      assert header(conn, "content-security-policy") =~ "default-src 'none'"
      assert header(conn, "content-security-policy") =~ "sandbox"
      assert header(conn, "x-content-type-options") == "nosniff"

      # the revision cannot be used to mint cache entries
      for rev <- ["1", "999", "-1", "abc", "0x"] do
        assert get(build_conn(), "/embedpdf/d/#{id}/#{rev}/p/0.svg").status == 404
      end

      assert get(build_conn(), "/embedpdf/d/#{id}/0/snapshot/99.svg?x0=0&y0=0&x1=9&y1=9").status ==
               404
    end

    test "download names cannot break out of the header", %{id: id} do
      conn = get(build_conn(), "/embedpdf/d/#{id}/download")
      disposition = header(conn, "content-disposition")
      refute disposition =~ ~r/[\r\n]/
      assert disposition =~ ~s(attachment; filename="re_port__Set-Cookie_ x_1 _.pdf")
      assert disposition =~ "filename*=UTF-8''re%22port"
      assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
    end

    test "attachments are only ever downloaded, never served as a page", %{doc: doc} do
      {doc, _} =
        EmbedPdf.Attachments.add(doc, "evil.html", "<script>alert(1)</script>", mime: "text/html")

      id = Store.put(doc, name: "with-attachment.pdf")
      [att] = EmbedPdf.Attachments.list(doc)
      conn = get(build_conn(), "/embedpdf/d/#{id}/attachment/#{att.id}")
      assert conn.status == 200
      assert header(conn, "content-type") =~ "application/octet-stream"
      assert header(conn, "content-disposition") =~ "attachment;"
      assert header(conn, "content-security-policy") == "sandbox"
    end

    test "ids that end up in generated CSS must be plain tokens" do
      assert get(build_conn(), "/embedpdf/probe/vAbc_123-x/7.css").status == 200

      for bad <- ["x\"]{}body{background:url(//evil)}", "a b", "a/../b", "é"] do
        assert get(build_conn(), "/embedpdf/probe/#{segment(bad)}/7.css").status == 404
        assert get(build_conn(), "/embedpdf/seen/#{segment(bad)}/3/7.css").status == 404
        assert get(build_conn(), "/embedpdf/seen/vOk/3/#{segment(bad)}.css").status == 404
      end
    end

    test "malformed numbers are ignored instead of raising" do
      long = "1" <> String.duplicate("0", 400)

      assert get(build_conn(), "/embedpdf/pointer?v=vX&p=0&w=600&h=800&pt.x=#{long}&pt.y=2").status ==
               204

      assert get(build_conn(), "/embedpdf/probe?v=vX&w=#{long}").status == 200
      assert get(build_conn(), "/embedpdf/seen?v=vX&p=#{long}&n=1").status == 200
    end

    test "pointer clicks arrive as fractions inside the page" do
      Phoenix.PubSub.subscribe(EmbedPdf.PubSub, "embed_pdf:viewer:vClamp")

      get(
        build_conn(),
        "/embedpdf/pointer?v=vClamp&p=0&w=100&h=100&pt.x=900&pt.y=-50&k=#{segment("<x>")}"
      )

      assert_receive {:embed_pdf, {:pointer, 0, 1.0, +0.0, nil}}
    end
  end

  describe "limits on work done for a document" do
    alias EmbedPdf.Limits

    test "work that fits runs and returns its result" do
      assert Limits.run(fn -> Enum.sum(1..100) end) == {:ok, 5050}

      assert {:ok, {:ok, _doc}} =
               Limits.run(fn -> EmbedPdf.open(File.read!(fixture("ebook.pdf"))) end)
    end

    test "work that never ends is stopped at the deadline" do
      loop = fn loop -> loop.(loop) end
      {elapsed, result} = :timer.tc(fn -> Limits.run(fn -> loop.(loop) end, time: 100) end)
      assert result == {:error, :timeout}
      assert elapsed < 2_000_000
    end

    test "work that asks for too much memory is stopped, and only that work" do
      grow = fn -> Enum.reduce(1..50_000_000, [], &[&1 | &2]) |> length() end
      assert Limits.run(grow, memory: 20_000_000) == {:error, :memory}
      assert Limits.run_or(grow, :fallback, memory: 20_000_000) == :fallback
      assert Process.alive?(self())
    end

    test "a crash is reported, not raised" do
      assert {:error, {:crash, _}} = Limits.run(fn -> raise "boom" end)
      assert {:error, {:crash, _}} = Limits.run(fn -> exit(:gone) end)
    end
  end

  describe "the render cache" do
    test "stays within its memory budget" do
      id = "budget-" <> Integer.to_string(System.unique_integer([:positive]))
      previous = Application.get_env(:embedpdf_ex, :render_cache_bytes)
      Application.put_env(:embedpdf_ex, :render_cache_bytes, 1_000)

      try do
        for n <- 1..20, do: Store.cached(id, {:blob, n}, fn -> String.duplicate("x", 400) end)
        [{:bytes, total}] = :ets.lookup(:embed_pdf_render_cache, :bytes)
        assert total <= 1_000
        # too big for the budget: computed but not kept
        assert Store.cached(id, :huge, fn -> String.duplicate("y", 5_000) end) =~ "yyy"
        assert :ets.lookup(:embed_pdf_render_cache, {id, :huge, :v}) == []
      after
        if previous,
          do: Application.put_env(:embedpdf_ex, :render_cache_bytes, previous),
          else: Application.delete_env(:embedpdf_ex, :render_cache_bytes)

        Store.delete(id)
      end
    end
  end

  describe "features are enforced on the server" do
    test "a read-only viewer ignores every event that would change the document" do
      view = mount_viewer("ebook-annotated.pdf", %{"read_only" => true})
      before = a(view)
      [annot | _] = Annotations.list(before.doc, 0)

      # none of these controls is rendered; the events are sent anyway
      render_click(view, "mode", %{"mode" => "annotate"})
      render_click(view, "tool", %{"tool" => "note"})
      send(view.pid, {:embed_pdf, {:pointer, 0, 0.5, 0.5, nil}})
      render_click(view, "select_annotation", %{"page" => "0", "id" => "#{annot.id}"})
      render_click(view, "delete_annotation", %{"page" => "0", "id" => "#{annot.id}"})
      render_keydown(view, "key", %{"key" => "Delete"})
      render_click(view, "duplicate_annotation", %{})
      render_click(view, "nudge", %{"dx" => "5", "dy" => "5"})
      render_click(view, "stamp", %{"stamp" => "approved"})
      send(view.pid, {:embed_pdf, {:pointer, 0, 0.3, 0.3, nil}})
      render_click(view, "pages", %{"op" => "delete"})
      render_click(view, "redact_apply", %{})
      render_click(view, "save_props", %{"props" => %{"title" => "changed"}})
      render_click(view, "outline_add", %{"title" => "x"})
      render_click(view, "reply", %{"aid" => "#{annot.id}", "text" => "hi"})
      render_click(view, "form_reset", %{})
      render_click(view, "sign", %{"name" => "Mallory", "how" => "seal"})
      render_click(view, "undo", %{})
      render(view)

      now = a(view)
      assert now.mode == :view
      assert now.tool == :pointer
      assert now.doc == before.doc
      assert now.rev == before.rev
      assert Store.get(now.doc_id).revision == 0
      assert now.history == %{undo: [], redo: []}

      # no upload for inserting pages or attaching files either
      refute Map.has_key?(now.uploads, :insert)
      refute Map.has_key?(now.uploads, :attachment)
    end

    test "a feature that is off cannot be used through its events" do
      view =
        mount_viewer("ebook.pdf", %{
          "features" => %{"redaction" => false, "signatures.signing" => false, "stamps" => false}
        })

      render_click(view, "mode", %{"mode" => "redact"})
      assert a(view).mode == :view
      render_click(view, "tool", %{"tool" => "redact_area"})
      render_click(view, "tool", %{"tool" => "signature"})
      render_click(view, "stamp", %{"stamp" => "approved"})
      assert a(view).tool == :pointer
      render_click(view, "sign_field", %{"field" => "1"})
      assert a(view).signing == nil

      # while one that is on still works
      render_click(view, "mode", %{"mode" => "shapes"})
      render_click(view, "tool", %{"tool" => "square"})
      assert a(view).tool == :square
      send(view.pid, {:embed_pdf, {:pointer, 0, 0.1, 0.1, nil}})
      send(view.pid, {:embed_pdf, {:pointer, 0, 0.3, 0.3, nil}})
      render(view)
      assert [_] = Annotations.list(a(view).doc, 0)
    end

    test "unknown modes, tools and panels are refused rather than turned into atoms" do
      view = mount_viewer("ebook.pdf", %{})
      render_click(view, "mode", %{"mode" => "Elixir.System"})
      render_click(view, "tool", %{"tool" => "infinity"})
      render_click(view, "panel", %{"side" => "right", "panel" => "error"})
      assert a(view).mode == :view
      assert a(view).tool == :pointer
      assert a(view).right == nil
      assert Process.alive?(view.pid)
    end
  end

  describe "markup built from a document" do
    test "only web, mail and phone addresses become links" do
      safe = &EmbedPdf.Live.PageComponent.safe_url/1
      assert safe.("https://example.com/a?b=1") == "https://example.com/a?b=1"
      assert safe.("mailto:a@example.com") == "mailto:a@example.com"

      for url <- [
            "javascript:alert(1)",
            " javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "vbscript:x",
            "file:///etc/passwd",
            "http:javascript:alert(1)",
            "x\nhttps://example.com",
            nil
          ] do
        assert safe.(url) == "#"
      end
    end

    test "a link typed by the user is stored only when it is such an address" do
      view = mount_viewer("ebook.pdf", %{})
      render_click(view, "mode", %{"mode" => "insert"})

      for {url, kept} <- [{"javascript:alert(1)", 0}, {"https://example.com/", 1}] do
        if a(view).tool != :link, do: render_click(view, "tool", %{"tool" => "link"})
        send(view.pid, {:embed_pdf, {:pointer, 0, 0.1, 0.1, nil}})
        send(view.pid, {:embed_pdf, {:pointer, 0, 0.3, 0.2, nil}})
        render(view)
        render_click(view, "link_create", %{"url" => url})
        assert length(EmbedPdf.Links.list(a(view).doc, 0)) == kept
      end
    end

    test "a named action whose name is not a name is no link, and does not crash the page" do
      alias EmbedPdf.PDF.Document
      doc = open!("ebook.pdf")
      {doc, link} = EmbedPdf.Links.add(doc, 0, {10, 10, 100, 40}, {:uri, "https://example.com/"})
      dict = Document.resolve(doc, {:ref, link.id, 0})
      action = %{"S" => "Named", "N" => %{"x" => {:string, "y"}}}
      doc = Document.put_object(doc, {:ref, link.id, 0}, Map.put(dict, "A", action))

      id = Store.put(doc, name: "named.pdf")

      {:ok, view, _} =
        live_isolated(build_conn(), EmbedPdf.Live.Viewer, session: %{"doc_id" => id})

      send(view.pid, {:embed_pdf, {:page_loaded, 0}})
      assert render(view) =~ "epdf-page"
      assert Process.alive?(view.pid)
    end

    test "an id prefix that is not a plain name is replaced" do
      doc = open!("welcome.pdf")

      svg =
        doc
        |> EmbedPdf.render_svg(0, id_prefix: "p\"><script>alert(1)</script>")
        |> IO.iodata_to_binary()

      refute svg =~ "<script"

      assert doc |> EmbedPdf.render_svg(0, id_prefix: "mine") |> IO.iodata_to_binary() =~
               ~s(id="mine)
    end
  end

  describe "signatures" do
    defp changed_after_signing do
      bytes = File.read!(fixture("signatures/signed_two_approvals.pdf"))
      {:ok, doc} = EmbedPdf.open(bytes)
      {changed, _} = Annotations.add(doc, 0, %{subtype: :square, rect: {10, 10, 60, 60}})
      entry = %Store.Entry{doc: changed, meta: EmbedPdf.Output.original_meta(bytes, doc)}
      {bytes, EmbedPdf.Output.bytes(entry)}
    end

    test "a later signed revision keeps an earlier signature valid" do
      {bytes, _} = changed_after_signing()

      assert [
               %{status: :valid, covers_whole_document?: false, changed_after: :signed},
               %{status: :valid, covers_whole_document?: true, changed_after: nil}
             ] = EmbedPdf.Signatures.validate(bytes)
    end

    test "unsigned changes after signing are never reported as plain valid" do
      {_, appended} = changed_after_signing()
      results = EmbedPdf.Signatures.validate(appended)

      assert length(results) == 2

      for r <- results do
        assert r.status == :modified
        assert r.changed_after == :unsigned
        # the signed bytes themselves are still intact
        assert r.digest_ok? and r.signature_ok?
      end
    end

    test "the viewer does not show the green banner for such a document" do
      {bytes, appended} = changed_after_signing()

      for {pdf, state} <- [{bytes, "is-valid"}, {appended, "is-modified"}] do
        {:ok, doc} = EmbedPdf.open(pdf)
        id = Store.put(doc, name: "signed.pdf", meta: EmbedPdf.Output.original_meta(pdf, doc))

        {:ok, view, _} =
          live_isolated(build_conn(), EmbedPdf.Live.Viewer, session: %{"doc_id" => id})

        [_, class] = Regex.run(~r/class="epdf-sigbar ([^"]*)"/, render(view))
        assert class == state
      end
    end
  end

  describe "the embedded viewer's session" do
    test "does not show the browser the file path or the document password" do
      path = fixture("demo_protected.pdf")

      {:ok, view, html} =
        live_isolated(build_conn(), EmbedPdf.TestHostLive,
          session: %{"path" => path, "password" => "embedpdf"}
        )

      # the nested viewer opened the protected document
      assert html =~ "/ 14"
      viewer = find_live_child(view, "host-viewer")
      assert a(viewer).status == :ready

      # its session token is readable by the client: neither secret is in it
      [_, token] = Regex.run(~r/id="host-viewer"[^>]*data-phx-session="([^"]+)"/, html)
      [_, payload, _] = String.split(token, ".")
      readable = Base.url_decode64!(payload, padding: false)
      refute readable =~ "password"
      refute readable =~ Path.dirname(path)
      assert readable =~ "sealed"
    end

    test "a tampered sealed value is ignored" do
      assert EmbedPdf.Live.unseal(%{"sealed" => "garbage", "name" => "x"}, @endpoint) == %{
               "name" => "x"
             }
    end
  end
end
