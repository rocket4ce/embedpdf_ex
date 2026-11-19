defmodule EmbedPdf.Live.ViewerTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import EmbedPdf.TestHelpers

  alias EmbedPdf.Live.Layout

  @endpoint EmbedPdf.TestEndpoint

  defp mount_viewer(file, extra \\ %{}) do
    {:ok, view, html} =
      live_isolated(build_conn(), EmbedPdf.Live.Viewer,
        session:
          Map.merge(
            %{
              "path" => fixture(file),
              "features" => %{"redaction" => true, "measurement" => true}
            },
            extra
          )
      )

    {view, html}
  end

  defp viewer_id(view), do: :sys.get_state(view.pid).socket.assigns.viewer_id
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "renders the toolbar, every page and the pager" do
    {view, html} = mount_viewer("ebook.pdf")
    assert html =~ "epdf-topbar"
    assert html =~ "/ 4"
    assert view |> element(".epdf-tab", "Annotate") |> has_element?()
    assert length(Floki_like.pages(render(view))) == 4
  end

  test "probe reports set the container size and fit-width scale" do
    {view, _} = mount_viewer("ebook.pdf")
    send(view.pid, {:embed_pdf, {:probe, :width, 1216}})
    send(view.pid, {:embed_pdf, {:probe, :height, 784}})
    html = render(view)
    a = assigns(view)
    assert {1224.0, 792.0} = a.container
    expected = (1224.0 - 2 * Layout.gap()) / 612
    assert html =~ "--epdf-scale:#{:erlang.float_to_binary(expected, decimals: 3)}"
    assert a.probe_nonce > 1
  end

  test "zoom controls" do
    {view, _} = mount_viewer("ebook.pdf")
    view |> element("button[aria-label='Zoom in']") |> render_click()
    assert assigns(view).zoom.mode == :absolute
    render_click(view, "zoom", %{"to" => "150"})
    assert render(view) =~ "150%"
    render_click(view, "zoom", %{"to" => "fit_page"})
    assert assigns(view).zoom.mode == :fit_page
  end

  test "page navigation and server-driven scroll anchor" do
    {view, _} = mount_viewer("ebook.pdf")
    render_click(view, "page", %{"to" => "next"})
    assert assigns(view).current_page == 1
    html = render(view)
    assert html =~ ~s(href="##{viewer_id(view)}-page-1")
    render_click(view, "page", %{"to" => "last"})
    assert assigns(view).current_page == 3
    view |> form(".epdf-page-input", %{"page" => "2"}) |> render_submit()
    assert assigns(view).current_page == 1
  end

  test "rotation swaps page dimensions in the URL and layout" do
    {view, _} = mount_viewer("ebook.pdf")
    render_click(view, "rotate", %{"dir" => "cw"})
    assert assigns(view).rotation == 90
    assert render(view) =~ "p/0.svg?r=90"
  end

  test "search finds hits and highlights them" do
    {view, _} = mount_viewer("ebook.pdf")
    render_click(view, "panel", %{"side" => "right", "panel" => "search"})
    html = view |> form(".epdf-search", %{"q" => "integration"}) |> render_change()
    assert html =~ "epdf-result"
    assert assigns(view).search.hits != []
    render_click(view, "search_nav", %{"dir" => "next"})
    assert assigns(view).search.current == 1
  end

  test "page image requests load the selectable text layer" do
    {view, _} = mount_viewer("ebook.pdf")
    send(view.pid, {:embed_pdf, {:page_loaded, 1}})
    html = render(view)
    assert html =~ "epdf-text-layer"
    assert html =~ "integration"
    assert html =~ ~s(phx-click="word")
  end

  test "pointer clicks drive point tools (measure)" do
    {view, _} = mount_viewer("ebook.pdf")
    render_click(view, "mode", %{"mode" => "insert"})
    render_click(view, "tool", %{"tool" => "measure"})
    assert render(view) =~ ~s(type="image")
    send(view.pid, {:embed_pdf, {:pointer, 0, 0.0, 0.5, nil}})
    send(view.pid, {:embed_pdf, {:pointer, 0, 0.5, 0.5, nil}})
    html = render(view)
    assert html =~ "4.25 in"
  end

  test "keyboard shortcuts" do
    {view, _} = mount_viewer("ebook.pdf")
    render_keydown(view, "key", %{"key" => "End"})
    assert assigns(view).current_page == 3
    render_keydown(view, "key", %{"key" => "Home"})
    assert assigns(view).current_page == 0
    render_keydown(view, "key", %{"key" => "?"})
    assert render(view) =~ "Keyboard shortcuts"
  end

  test "protected documents ask for the password" do
    {view, html} = mount_viewer("demo_protected.pdf")
    assert html =~ "Password required"
    view |> form(".epdf-dialog form", %{"password" => "wrong"}) |> render_submit()
    assert render(view) =~ "Incorrect password"
    view |> form(".epdf-dialog form", %{"password" => "embedpdf"}) |> render_submit()
    assert assigns(view).status == :ready
  end

  test "spanish interface" do
    {_view, html} = mount_viewer("ebook.pdf", %{"locale" => "es"})
    assert html =~ "Anotar"
    assert html =~ "Censurar"
  end

  test "read-only hides editing modes" do
    {_view, html} = mount_viewer("ebook.pdf", %{"read_only" => true})
    refute html =~ "Annotate"
    refute html =~ "Redact"
  end
end

defmodule Floki_like do
  @moduledoc false
  def pages(html), do: Regex.scan(~r/class="epdf-page[ "]/, html)
end
