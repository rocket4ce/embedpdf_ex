defmodule EmbedPdf.Live.FixturesSmokeTest do
  # Drives the viewer through its main features on every example PDF: each
  # page image, the text layers, the view controls, the panels, search, every
  # mode and tool with pointer clicks, undo, download and print.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import EmbedPdf.TestHelpers

  @endpoint EmbedPdf.TestEndpoint

  @passwords %{"demo_protected.pdf" => "embedpdf"}

  @fixtures [__DIR__, "..", "..", "fixtures"]
            |> Path.join()
            |> Path.expand()
            |> then(fn dir ->
              for pattern <- ["*.pdf", "render/*.pdf", "signatures/*.pdf"],
                  path <- Path.wildcard(Path.join(dir, pattern)),
                  do: Path.relative_to(path, dir)
            end)
            |> Enum.sort()

  defp a(view), do: :sys.get_state(view.pid).socket.assigns

  defp values(html, event, key) do
    ~r/phx-click="#{event}"[^>]*phx-value-#{key}="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
  end

  defp ok!(view, label) do
    assert Process.alive?(view.pid), "viewer crashed after #{label}"
    render(view)
  end

  for file <- @fixtures do
    @file_name file

    @tag timeout: 120_000
    test "the viewer works end to end on #{file}" do
      file = @file_name
      password = @passwords[Path.basename(file)]

      session =
        %{
          "path" => fixture(file),
          "features" => %{
            "redaction" => true,
            "measurement" => true,
            "snapshots" => true,
            "forms.building" => true
          }
        }
        |> then(&if password, do: Map.put(&1, "password", password), else: &1)

      {:ok, view, html} = live_isolated(build_conn(), EmbedPdf.Live.Viewer, session: session)
      {:ok, doc} = EmbedPdf.open(File.read!(fixture(file)), password: password)
      pages = EmbedPdf.page_count(doc)

      assert a(view).status == :ready
      assert html =~ "/ #{pages}"
      doc_id = a(view).doc_id

      # every page image, and the text layer it triggers
      for n <- 0..(pages - 1) do
        conn = get(build_conn(), "/embedpdf/d/#{doc_id}/#{a(view).rev}/p/#{n}.svg")
        assert conn.status == 200, "page #{n + 1} image failed"
        assert conn.resp_body =~ "<svg"
        send(view.pid, {:embed_pdf, {:page_loaded, n}})
      end

      html = ok!(view, "loading every page")
      assert html =~ "epdf-page"

      # view controls
      send(view.pid, {:embed_pdf, {:probe, :width, 1216}})
      send(view.pid, {:embed_pdf, {:probe, :height, 784}})

      for to <- ~w(in out fit_page fit_width 150 100),
          do: render_click(view, "zoom", %{"to" => to})

      for dir <- ~w(cw cw ccw ccw), do: render_click(view, "rotate", %{"dir" => dir})
      for m <- ~w(odd even none), do: render_click(view, "spread", %{"mode" => m})

      for m <- ~w(horizontal paged vertical),
          do: render_click(view, "scroll_mode", %{"mode" => m})

      for to <- ~w(next last prev first), do: render_click(view, "page", %{"to" => to})
      render_click(view, "goto_page", %{"page" => "#{pages}"})

      for key <- ~w(ArrowRight ArrowLeft + - r End Home ?),
          do: render_keydown(view, "key", %{"key" => key})

      render_click(view, "close_dialog", %{})
      ok!(view, "view controls")

      # panels and dialogs
      for {side, panel} <- [
            {"left", "thumbnails"},
            {"left", "outline"},
            {"left", "attachments"},
            {"right", "search"},
            {"right", "comments"},
            {"right", "signatures"}
          ] do
        render_click(view, "panel", %{"side" => side, "panel" => panel})
        ok!(view, "opening the #{panel} panel")
      end

      for d <- ~w(properties shortcuts print) do
        render_click(view, "dialog", %{"dialog" => d})
        ok!(view, "the #{d} dialog")
        render_click(view, "close_dialog", %{})
      end

      # search
      render_change(view, "search", %{"q" => "e"})
      render_click(view, "search_nav", %{"dir" => "next"})
      render_click(view, "search_nav", %{"dir" => "prev"})
      ok!(view, "searching")
      render_click(view, "search_clear", %{})

      # every mode, every tool, with clicks on the first page; a fresh viewer
      # with only that page loaded keeps long documents quick
      {:ok, view, _html} = live_isolated(build_conn(), EmbedPdf.Live.Viewer, session: session)
      doc_id = a(view).doc_id
      send(view.pid, {:embed_pdf, {:page_loaded, 0}})
      html = render(view)
      modes = values(html, "mode", "mode")
      assert "view" in modes

      for mode <- modes do
        html = render_click(view, "mode", %{"mode" => mode})

        for tool <- values(html, "tool", "tool") do
          render_click(view, "tool", %{"tool" => tool})
          assert a(view).tool == String.to_existing_atom(tool)

          for {x, y} <- [{0.2, 0.2}, {0.5, 0.4}, {0.6, 0.6}] do
            send(view.pid, {:embed_pdf, {:pointer, 0, x, y, nil}})
            ok!(view, "a click with the #{tool} tool in #{mode} mode")
          end

          render_click(view, "finish_tool", %{})
          render_click(view, "close_dialog", %{})
          render_click(view, "snapshot_close", %{})
          render_click(view, "cancel_tool", %{})
          ok!(view, "finishing the #{tool} tool in #{mode} mode")
        end
      end

      render_click(view, "mode", %{"mode" => "view"})
      assert length(modes) >= 5, "only found the modes #{inspect(modes)}"
      assert a(view).history.undo != [], "no tool changed the document"
      assert EmbedPdf.Annotations.all(a(view).doc) != []

      # what the tools drew can be saved, read back and printed
      for flatten <- ["", "?flatten=1"] do
        conn = get(build_conn(), "/embedpdf/d/#{doc_id}/download#{flatten}")
        assert conn.status == 200
        assert {:ok, saved} = EmbedPdf.open(conn.resp_body)
        assert EmbedPdf.page_count(saved) == pages
      end

      conn = get(build_conn(), "/embedpdf/d/#{doc_id}/#{a(view).rev}/print")
      assert conn.status == 200

      for n <- 0..(pages - 1) do
        conn = get(build_conn(), "/embedpdf/d/#{doc_id}/#{a(view).rev}/p/#{n}.svg")
        assert conn.status == 200, "page #{n + 1} image failed after editing"
      end

      # and all of it can be undone
      for _ <- 1..200, a(view).history.undo != [], do: render_click(view, "undo", %{})
      ok!(view, "undoing everything")
      assert Enum.map(a(view).sizes, & &1) != []
    end
  end
end
