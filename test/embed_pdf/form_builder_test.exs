defmodule EmbedPdf.FormBuilderTest do
  use ExUnit.Case, async: true
  import EmbedPdf.TestHelpers

  alias EmbedPdf.{Forms, PdfCheck}
  alias EmbedPdf.PDF.Document

  defp names(doc), do: doc |> Forms.fields() |> Enum.map(& &1.name)

  test "adds every field type to a document without a form" do
    doc = open!("ebook.pdf")
    assert Forms.fields(doc) == []

    {doc, text} = Forms.add_field(doc, 0, {50, 700, 250, 724}, :text, value: "Hello")
    {doc, check} = Forms.add_field(doc, 0, {50, 660, 68, 678}, :checkbox, checked: true)
    {doc, radio} = Forms.add_field(doc, 0, {50, 620, 68, 638}, :radio)

    {doc, combo} =
      Forms.add_field(doc, 0, {50, 580, 190, 604}, :combo,
        options: ["React", "Vue"],
        value: "Vue"
      )

    {doc, list} =
      Forms.add_field(doc, 0, {50, 500, 190, 572}, :list,
        options: [{"a", "Alpha"}, {"b", "Beta"}]
      )

    {doc, button} = Forms.add_field(doc, 1, {50, 460, 150, 488}, :button, caption: "Submit")
    {doc, sig} = Forms.add_field(doc, 1, {50, 400, 210, 448}, :signature)

    assert text.name == "Text1" and text.type == :text and text.value == "Hello"
    assert check.name == "Check Box1" and check.value == true
    assert radio.name == "Group1" and radio.type == :radio

    assert combo.name == "Dropdown1" and combo.value == "Vue" and
             combo.options == [{"React", "React"}, {"Vue", "Vue"}]

    assert list.name == "List Box1" and list.options == [{"a", "Alpha"}, {"b", "Beta"}]
    assert button.name == "Button1" and button.type == :button
    assert sig.name == "Signature1" and sig.type == :signature
    assert hd(button.widgets).page == 1

    # widgets are on their pages and have appearances
    for field <- [text, check, radio, combo, list, button, sig], w <- field.widgets do
      dict = Document.resolve(doc, {:ref, w.id, 0})
      assert dict["Subtype"] == "Widget"
      assert Document.get_in(doc, dict, ["AP", "N"]) != nil
      page = Document.page(doc, w.page)
      assert {:ref, w.id, 0} in EmbedPdf.Edit.annots(doc, page)
    end

    form = Document.get(doc, Document.catalog(doc), "AcroForm")
    assert %{"Helv" => _, "ZaDb" => _} = Document.get_in(doc, form, ["DR", "Font"])

    again = PdfCheck.roundtrip!(doc, "builder-all")
    assert length(Forms.fields(again)) == 7
    assert Forms.get(again, "Dropdown1").value == "Vue"
  end

  test "names are unique and specific names are kept" do
    doc = open!("ebook.pdf")
    {doc, a} = Forms.add_field(doc, 0, {10, 10, 100, 30}, :text)
    {doc, b} = Forms.add_field(doc, 0, {10, 40, 100, 60}, :text)
    {doc, c} = Forms.add_field(doc, 0, {10, 70, 100, 90}, :text, name: "email")
    {doc, d} = Forms.add_field(doc, 0, {10, 100, 100, 120}, :text, name: "email")
    assert [a.name, b.name, c.name, d.name] == ["Text1", "Text2", "email", "email1"]
    assert names(doc) == ["Text1", "Text2", "email", "email1"]
  end

  test "radio buttons join a group by name with the next Choice value" do
    doc = open!("ebook.pdf")
    {doc, g} = Forms.add_field(doc, 0, {50, 620, 68, 638}, :radio)
    {doc, g} = Forms.add_field(doc, 0, {80, 620, 98, 638}, :radio, name: g.name)
    {doc, g} = Forms.add_field(doc, 0, {110, 620, 128, 638}, :radio, name: g.name, checked: true)

    assert length(Forms.fields(doc)) == 1
    assert Enum.map(g.widgets, & &1.on_state) == ["Choice1", "Choice2", "Choice3"]
    assert g.value == "Choice3"

    doc = Forms.set_value(doc, g.id, "Choice1")
    assert Forms.get(doc, g.id).value == "Choice1"
    assert Forms.get(PdfCheck.roundtrip!(doc, "builder-radio"), g.name).widgets |> length() == 3
  end

  test "a merged radio field (field and widget in one dictionary) is split to add a button" do
    doc = open!("form-sample.pdf")

    case Enum.find(Forms.fields(doc), &(&1.type == :radio)) do
      nil ->
        :ok

      radio ->
        count = length(radio.widgets)
        {doc, g} = Forms.add_field(doc, 0, {10, 10, 28, 28}, :radio, name: radio.name)
        assert length(g.widgets) == count + 1
        PdfCheck.roundtrip!(doc, "builder-split")
    end
  end

  test "update_field changes settings and regenerates appearances" do
    doc = open!("ebook.pdf")
    {doc, t} = Forms.add_field(doc, 0, {50, 700, 250, 724}, :text, value: "abc")

    {doc, t} =
      Forms.update_field(doc, t.id,
        name: "Email",
        required?: true,
        read_only?: true,
        multiline?: true,
        max_len: 5,
        text_align: :right,
        font_size: 9,
        default: "x@y.z",
        border_color: {1.0, 0.0, 0.0},
        background_color: nil
      )

    assert t.name == "Email"
    assert t.required? and t.read_only? and t.multiline?
    assert t.max_len == 5 and t.text_align == :right and t.default == "x@y.z"
    assert EmbedPdf.Forms.Builder.font_size(doc, t) == 9.0

    {doc, t} = Forms.update_field(doc, t.id, required?: false, max_len: nil)
    refute t.required?
    assert t.max_len == nil

    {doc, c} =
      Forms.add_field(doc, 0, {50, 600, 190, 624}, :combo, options: ["a", "b"], value: "b")

    {doc, c} = Forms.update_field(doc, c.id, options: ["a", "c"])
    assert c.options == [{"a", "a"}, {"c", "c"}]
    assert c.value in [nil, ""]

    {doc, cb} = Forms.add_field(doc, 0, {50, 560, 68, 578}, :checkbox, checked: true)
    {doc, cb} = Forms.update_field(doc, cb.id, export: "Agree")
    assert hd(cb.widgets).on_state == "Agree"
    assert cb.value == true

    {doc, b} = Forms.add_field(doc, 0, {50, 500, 150, 528}, :button, caption: "Go")
    {doc, _b} = Forms.update_field(doc, b.id, caption: "Send")
    w = hd(b.widgets)
    ap = Document.get_in(doc, Document.resolve(doc, {:ref, w.id, 0}), ["AP", "N"])
    assert Document.stream_data(doc, ap) =~ "Send"

    PdfCheck.roundtrip!(doc, "builder-update")
  end

  test "renaming keeps names unique" do
    doc = open!("ebook.pdf")
    {doc, a} = Forms.add_field(doc, 0, {10, 10, 100, 30}, :text, name: "name")
    {doc, b} = Forms.add_field(doc, 0, {10, 40, 100, 60}, :text)
    {_doc, b} = Forms.update_field(doc, b.id, name: "name")
    assert a.name == "name"
    assert b.name == "name1"
  end

  test "move, resize, duplicate and delete" do
    doc = open!("ebook.pdf")
    {doc, t} = Forms.add_field(doc, 0, {50, 700, 250, 724}, :text, value: "v")
    wid = hd(t.widgets).id

    {doc, t} = Forms.move_field(doc, wid, 10, -20)
    assert hd(t.widgets).rect == {60.0, 680.0, 260.0, 704.0}

    {doc, t} = Forms.resize_field(doc, wid, {60, 600, 300, 704})
    assert hd(t.widgets).rect == {60.0, 600.0, 300.0, 704.0}
    ap = Document.get_in(doc, Document.resolve(doc, {:ref, wid, 0}), ["AP", "N"])
    assert Document.resolve(doc, ap).dict["BBox"] == [0, 0, 240, 104]

    {doc, d} = Forms.duplicate_field(doc, t.id)
    assert d.name == "Text2"
    assert d.value == "v"
    {x0, _, _, _} = hd(d.widgets).rect
    assert x0 == 70.0

    {doc, r} = Forms.add_field(doc, 0, {50, 400, 68, 418}, :radio)
    {doc, r2} = Forms.duplicate_field(doc, hd(r.widgets).id)
    assert r2.id == r.id and length(r2.widgets) == 2

    doc = Forms.delete_field(doc, t.id)
    refute Enum.any?(Forms.fields(doc), &(&1.id == t.id))
    refute {:ref, wid, 0} in EmbedPdf.Edit.annots(doc, Document.page(doc, 0))

    doc = Forms.delete_field(doc, hd(r2.widgets).id)
    assert Enum.map(Forms.fields(doc), & &1.name) == ["Text2"]

    again = PdfCheck.roundtrip!(doc, "builder-geometry")
    assert Enum.map(Forms.fields(again), & &1.name) == ["Text2"]
  end

  test "new fields work in a document that already has a form" do
    doc = open!("forms.pdf")
    before = length(Forms.fields(doc))
    {doc, t} = Forms.add_field(doc, 0, {400, 40, 560, 64}, :text)
    assert length(Forms.fields(doc)) == before + 1
    doc = Forms.set_value(doc, t.id, "Filled")
    assert Forms.get(doc, t.id).value == "Filled"
    assert Forms.get(PdfCheck.roundtrip!(doc, "builder-existing"), t.name).value == "Filled"
  end
end
