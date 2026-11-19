defmodule EmbedPdf.Web.PlugTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import EmbedPdf.TestHelpers

  @endpoint EmbedPdf.TestEndpoint

  setup do
    doc = open!("welcome.pdf")
    {:ok, id: EmbedPdf.Store.put(doc, name: "welcome.pdf"), doc: doc}
  end

  test "serves page SVGs and notifies the viewer", %{id: id} do
    Phoenix.PubSub.subscribe(EmbedPdf.PubSub, "embed_pdf:viewer:abc")
    conn = get(build_conn(), "/embedpdf/d/#{id}/0/p/1.svg?r=90&v=abc")
    assert conn.status == 200
    assert hd(Plug.Conn.get_resp_header(conn, "content-type")) =~ "image/svg+xml"
    assert conn.resp_body =~ "<svg"
    assert_receive {:embed_pdf, {:page_loaded, 1}}
  end

  test "unknown documents and pages are 404", %{id: id} do
    assert get(build_conn(), "/embedpdf/d/nope/0/p/0.svg").status == 404
    assert get(build_conn(), "/embedpdf/d/#{id}/0/p/99.svg").status == 404
  end

  test "downloads the PDF", %{id: id} do
    conn = get(build_conn(), "/embedpdf/d/#{id}/download")
    assert conn.status == 200
    assert String.starts_with?(conn.resp_body, "%PDF-")
    assert {:ok, _} = EmbedPdf.open(conn.resp_body)
    assert hd(Plug.Conn.get_resp_header(conn, "content-disposition")) =~ "welcome.pdf"
  end

  test "print view lists the chosen pages", %{id: id} do
    conn = get(build_conn(), "/embedpdf/d/#{id}/0/print?pages=2-3")
    assert conn.status == 200
    assert conn.resp_body =~ "/p/1.svg"
    assert conn.resp_body =~ "/p/2.svg"
    refute conn.resp_body =~ "/p/0.svg"
    refute conn.resp_body =~ "<script"
  end

  test "probe stylesheet and reports" do
    conn = get(build_conn(), "/embedpdf/probe/xyz/3.css")
    assert conn.resp_body =~ "@container epdfvp (min-width:160px)"
    assert conn.resp_body =~ "/embedpdf/probe?v=xyz&n=3&w=800"

    Phoenix.PubSub.subscribe(EmbedPdf.PubSub, "embed_pdf:viewer:xyz")
    conn = get(build_conn(), "/embedpdf/probe?v=xyz&n=3&w=800")
    assert conn.status == 200
    assert_receive {:embed_pdf, {:probe, :width, 800}}
  end

  test "pointer clicks answer 204 and forward fractions" do
    Phoenix.PubSub.subscribe(EmbedPdf.PubSub, "embed_pdf:viewer:ptr")
    conn = get(build_conn(), "/embedpdf/pointer?v=ptr&p=2&w=600&h=800&pt.x=150&pt.y=200")
    assert conn.status == 204
    assert_receive {:embed_pdf, {:pointer, 2, 0.25, 0.25, nil}}
  end

  test "page ranges" do
    assert EmbedPdf.Web.Plug.parse_ranges("1-3, 5, 9", 6) == [0, 1, 2, 4]
    assert EmbedPdf.Web.Plug.parse_ranges(nil, 3) == [0, 1, 2]
  end
end
