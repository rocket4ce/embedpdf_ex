defmodule EmbedPdf.Live.EditingTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import EmbedPdf.TestHelpers

  @endpoint EmbedPdf.TestEndpoint

  defp mount_viewer(file) do
    {:ok, view, _html} =
      live_isolated(build_conn(), EmbedPdf.Live.Viewer,
        session: %{"path" => fixture(file), "features" => %{"redaction" => true}}
      )

    view
  end

  defp a(view), do: :sys.get_state(view.pid).socket.assigns
  defp annots(view, page), do: EmbedPdf.Annotations.list(a(view).doc, page)

  test "highlight by clicking the first and last word, then undo and redo" do
    view = mount_viewer("ebook.pdf")
    send(view.pid, {:embed_pdf, {:page_loaded, 1}})
    render(view)
    render_click(view, "mode", %{"mode" => "annotate"})
    render_click(view, "tool", %{"tool" => "highlight"})

    pt = EmbedPdf.Text.page(a(view).doc, 1)
    {from, _} = EmbedPdf.Text.word_at(pt, 0)
    {_, to} = EmbedPdf.Text.word_at(pt, 12)
    render_click(view, "word", %{"p" => "1", "i" => "#{from}", "j" => "#{from + 2}"})
    assert a(view).anchor != nil
    render_click(view, "word", %{"p" => "1", "i" => "#{to - 1}", "j" => "#{to}"})

    [hl] = Enum.filter(annots(view, 1), &(&1.subtype == :highlight))
    assert hl.contents =~ "Let"
    assert a(view).dirty?
    assert a(view).page_revs[1] > 0

    render_click(view, "undo", %{})
    assert Enum.filter(annots(view, 1), &(&1.subtype == :highlight)) == []
    render_click(view, "redo", %{})
    assert [_] = Enum.filter(annots(view, 1), &(&1.subtype == :highlight))
  end

  test "rectangle from two clicks, then select, restyle, move and delete" do
    view = mount_viewer("ebook.pdf")
    render_click(view, "mode", %{"mode" => "shapes"})
    render_click(view, "tool", %{"tool" => "square"})
    send(view.pid, {:embed_pdf, {:pointer, 0, 0.1, 0.1, nil}})
    send(view.pid, {:embed_pdf, {:pointer, 0, 0.4, 0.3, nil}})
    render(view)
    [sq] = Enum.filter(annots(view, 0), &(&1.subtype == :square))
    {x0, _y0, x1, _y1} = sq.rect
    assert_in_delta x1 - x0, 0.3 * 612, 1.0

    render_click(view, "tool", %{"tool" => "square"})
    render_click(view, "select_annotation", %{"page" => "0", "id" => "#{sq.id}"})
    assert a(view).selected == {0, sq.id}
    render_click(view, "nudge", %{"dx" => "5", "dy" => "0"})
    [moved] = Enum.filter(annots(view, 0), &(&1.subtype == :square))
    assert_in_delta elem(moved.rect, 0), x0 + 5, 0.01

    render_click(view, "delete_annotation", %{})
    assert Enum.filter(annots(view, 0), &(&1.subtype == :square)) == []
  end

  test "sticky note, comment reply and comments panel" do
    view = mount_viewer("ebook.pdf")
    render_click(view, "mode", %{"mode" => "annotate"})
    render_click(view, "tool", %{"tool" => "note"})
    send(view.pid, {:embed_pdf, {:pointer, 0, 0.5, 0.5, nil}})
    html = render(view)
    assert html =~ "epdf-comment"
    [note] = Enum.filter(annots(view, 0), &(&1.subtype == :text))
    view |> form(".epdf-comment form", %{"text" => "Looks good"}) |> render_submit()
    [note] = Enum.filter(annots(view, 0), &(&1.id == note.id))
    assert Enum.any?(note.replies, &(&1.contents == "Looks good"))
  end

  test "ink from clicked points and Finish" do
    view = mount_viewer("ebook.pdf")
    render_click(view, "mode", %{"mode" => "annotate"})
    render_click(view, "tool", %{"tool" => "ink"})

    for {x, y} <- [{0.1, 0.1}, {0.2, 0.15}, {0.3, 0.1}],
        do: send(view.pid, {:embed_pdf, {:pointer, 0, x, y, nil}})

    assert render(view) =~ "epdf-preview"
    render_click(view, "finish_tool", %{})
    assert [_] = Enum.filter(annots(view, 0), &(&1.subtype == :ink))
  end

  test "stamp placement" do
    view = mount_viewer("ebook.pdf")
    render_click(view, "mode", %{"mode" => "insert"})
    render_click(view, "stamp", %{"stamp" => "draft"})
    send(view.pid, {:embed_pdf, {:pointer, 0, 0.5, 0.5, nil}})
    render(view)
    assert [st] = Enum.filter(annots(view, 0), &(&1.subtype == :stamp))
    assert st.icon in ["draft", "Draft"]
  end

  test "marking and applying a redaction removes the text" do
    view = mount_viewer("ebook.pdf")
    send(view.pid, {:embed_pdf, {:page_loaded, 1}})
    render(view)
    render_click(view, "mode", %{"mode" => "redact"})
    render_click(view, "tool", %{"tool" => "redact_text"})
    pt = EmbedPdf.Text.page(a(view).doc, 1)

    {:ok, %{from: from, to: to}} =
      pt |> EmbedPdf.Text.search("integration") |> List.first() |> then(&{:ok, &1})

    render_click(view, "word", %{"p" => "1", "i" => "#{from}", "j" => "#{to}"})
    render_click(view, "word", %{"p" => "1", "i" => "#{from}", "j" => "#{to}"})
    assert [_] = Enum.filter(annots(view, 1), &(&1.subtype == :redact))
    before = pt |> EmbedPdf.Text.search("integration") |> length()
    render_click(view, "redact_apply", %{})

    after_count =
      a(view).doc |> EmbedPdf.Text.page(1) |> EmbedPdf.Text.search("integration") |> length()

    assert after_count == before - 1
    assert Enum.filter(annots(view, 1), &(&1.subtype == :redact)) == []
  end

  test "form filling" do
    view = mount_viewer("form-sample.pdf")
    render_click(view, "mode", %{"mode" => "form"})
    [field | _] = Enum.filter(a(view).fields, &(&1.type == :text))

    render_change(view, "form_change", %{
      "_target" => ["field", "#{field.id}"],
      "field" => %{"#{field.id}" => "Ada"}
    })

    assert Enum.find(EmbedPdf.Forms.fields(a(view).doc), &(&1.id == field.id)).value == "Ada"
  end

  test "page operations" do
    view = mount_viewer("ebook.pdf")
    render_click(view, "mode", %{"mode" => "pages"})
    render_click(view, "page_select", %{"page" => "2"})
    render_click(view, "pages", %{"op" => "rotate_cw"})
    assert EmbedPdf.PDF.Document.page(a(view).doc, 2).rotate == 90
    render_click(view, "pages", %{"op" => "delete"})
    assert length(a(view).sizes) == 3
    render_click(view, "pages", %{"op" => "blank"})
    assert length(a(view).sizes) == 4
  end

  test "outline is listed and editable" do
    view = mount_viewer("links.pdf")
    render_click(view, "panel", %{"side" => "left", "panel" => "outline"})
    count = length(EmbedPdf.Outline.tree(a(view).doc))
    view |> form(".epdf-outline form", %{"title" => "My bookmark"}) |> render_submit()
    assert length(EmbedPdf.Outline.tree(a(view).doc)) == count + 1
    assert render(view) =~ "My bookmark"
  end
end
