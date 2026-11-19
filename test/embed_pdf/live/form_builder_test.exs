defmodule EmbedPdf.Live.FormBuilderTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import EmbedPdf.TestHelpers

  alias EmbedPdf.Forms

  @endpoint EmbedPdf.TestEndpoint

  defp mount_viewer(file, features \\ %{"forms.building" => true}) do
    {:ok, view, _html} =
      live_isolated(build_conn(), EmbedPdf.Live.Viewer,
        session: %{"path" => fixture(file), "features" => features}
      )

    view
  end

  defp a(view), do: :sys.get_state(view.pid).socket.assigns
  defp click(view, page, fx, fy), do: send(view.pid, {:embed_pdf, {:pointer, page, fx, fy, nil}})

  defp design(view) do
    render_click(view, "mode", %{"mode" => "form"})
    render_click(view, "field_design", %{"on" => "true"})
  end

  test "the design toggle and field tools only show with forms.building" do
    view = mount_viewer("ebook.pdf", %{})
    render_click(view, "mode", %{"mode" => "form"})
    refute render(view) =~ "field_design"

    view = mount_viewer("ebook.pdf")
    render_click(view, "mode", %{"mode" => "form"})
    html = render(view)
    assert html =~ "field_design"
    refute html =~ ~s(phx-value-tool="form_text")
    render_click(view, "field_design", %{"on" => "true"})
    assert render(view) =~ ~s(phx-value-tool="form_text")
  end

  test "a text field from two corners is created and selected" do
    view = mount_viewer("ebook.pdf")
    design(view)
    render_click(view, "tool", %{"tool" => "form_text"})
    assert render(view) =~ ~s(type="image")
    click(view, 0, 0.1, 0.1)
    click(view, 0, 0.5, 0.15)
    html = render(view)

    [field] = Forms.fields(a(view).doc)
    assert field.type == :text and field.name == "Text1"
    {x0, _y0, x1, _y1} = hd(field.widgets).rect
    assert_in_delta x1 - x0, 0.4 * 612, 1.0

    assert a(view).field == {0, hd(field.widgets).id}
    assert a(view).right == :field
    assert a(view).tool == :pointer
    assert html =~ "epdf-field-outline"
    assert html =~ "Field properties"
    assert a(view).dirty?
  end

  test "a single click places a field with the default size" do
    view = mount_viewer("ebook.pdf")
    design(view)
    render_click(view, "tool", %{"tool" => "form_checkbox"})
    click(view, 0, 0.2, 0.2)
    click(view, 0, 0.2, 0.2)
    [field] = Forms.fields(a(view).doc)
    assert field.type == :checkbox
    {x0, y0, x1, y1} = hd(field.widgets).rect
    assert_in_delta x1 - x0, 18, 0.01
    assert_in_delta y1 - y0, 18, 0.01
  end

  test "every tool creates its field type" do
    view = mount_viewer("ebook.pdf")
    design(view)

    for {tool, i} <- Enum.with_index(EmbedPdf.Live.FormDesign.tools()) do
      render_click(view, "tool", %{"tool" => to_string(tool)})
      y = 0.05 + i * 0.12
      click(view, 0, 0.1, y)
      click(view, 0, 0.4, y + 0.05)
      render(view)
    end

    types = a(view).doc |> Forms.fields() |> Enum.map(& &1.type) |> Enum.sort()
    assert types == Enum.sort([:text, :checkbox, :radio, :combo, :list, :button, :signature])
  end

  test "editing properties, nudging, moving, resizing, duplicating and deleting" do
    view = mount_viewer("ebook.pdf")
    design(view)
    render_click(view, "tool", %{"tool" => "form_combo"})
    click(view, 0, 0.1, 0.1)
    click(view, 0, 0.4, 0.14)
    render(view)
    [field] = Forms.fields(a(view).doc)
    wid = hd(field.widgets).id

    view
    |> form("##{a(view).viewer_id}-field-props", %{
      "f" => %{
        "name" => "Framework",
        "options" => "React\nvue|Vue.js",
        "required" => "true",
        "align" => "center"
      }
    })
    |> render_submit()

    field = Forms.get(a(view).doc, field.id)
    assert field.name == "Framework"
    assert field.options == [{"React", "React"}, {"vue", "Vue.js"}]
    assert field.required?
    assert field.text_align == :center

    {x0, y0, _, _} = hd(field.widgets).rect
    render_click(view, "field_nudge", %{"dx" => "2", "dy" => "0"})
    {nx0, ny0, _, _} = hd(Forms.get(a(view).doc, field.id).widgets).rect
    assert_in_delta nx0, x0 + 2, 0.01
    assert_in_delta ny0, y0, 0.01

    render_click(view, "field_action", %{"action" => "move"})
    assert a(view).field_action == :move
    assert render(view) =~ ~s(type="image")
    click(view, 0, 0.5, 0.5)
    render(view)
    {mx0, my0, mx1, my1} = hd(Forms.get(a(view).doc, field.id).widgets).rect
    assert_in_delta (mx0 + mx1) / 2, 306, 0.5
    assert_in_delta (my0 + my1) / 2, 396, 0.5
    assert a(view).field_action == nil

    render_click(view, "field_action", %{"action" => "resize"})
    click(view, 0, 0.9, 0.6)
    render(view)
    {_rx0, ry0, rx1, _ry1} = hd(Forms.get(a(view).doc, field.id).widgets).rect
    assert_in_delta rx1, 0.9 * 612, 0.5
    assert_in_delta ry0, 792 - 0.6 * 792, 0.5

    render_click(view, "field_duplicate", %{})
    assert length(Forms.fields(a(view).doc)) == 2
    {_, new_wid} = a(view).field
    refute new_wid == wid

    render_click(view, "field_select", %{"page" => "0", "id" => "#{wid}"})
    assert a(view).field == {0, wid}
    render_keydown(view, "key", %{"key" => "Delete"})
    assert length(Forms.fields(a(view).doc)) == 1
    assert a(view).field == nil

    render_click(view, "undo", %{})
    assert length(Forms.fields(a(view).doc)) == 2
  end

  test "checkbox export value and default, and filling a built field" do
    view = mount_viewer("ebook.pdf")
    design(view)
    render_click(view, "tool", %{"tool" => "form_checkbox"})
    click(view, 0, 0.1, 0.1)
    click(view, 0, 0.1, 0.1)
    render(view)
    [field] = Forms.fields(a(view).doc)

    view
    |> form("##{a(view).viewer_id}-field-props", %{
      "f" => %{"export" => "Agree", "default" => "true"}
    })
    |> render_submit()

    field = Forms.get(a(view).doc, field.id)
    assert hd(field.widgets).on_state == "Agree"

    render_click(view, "field_design", %{"on" => "false"})
    html = render(view)
    assert html =~ ~s(name="field[#{field.id}]")
    refute html =~ "epdf-field-outline"

    render_change(view, "form_change", %{
      "_target" => ["field", "#{field.id}"],
      "field" => %{"#{field.id}" => "true"}
    })

    assert Forms.get(a(view).doc, field.id).value == true
  end

  test "escape cancels a pending field move" do
    view = mount_viewer("ebook.pdf")
    design(view)
    render_click(view, "tool", %{"tool" => "form_text"})
    click(view, 0, 0.1, 0.1)
    click(view, 0, 0.1, 0.1)
    render(view)
    render_click(view, "field_action", %{"action" => "move"})
    render_keydown(view, "key", %{"key" => "Escape"})
    assert a(view).field_action == nil
  end
end
