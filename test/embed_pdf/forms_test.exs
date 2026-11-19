defmodule EmbedPdf.FormsTest do
  use ExUnit.Case, async: true
  import EmbedPdf.TestHelpers

  alias EmbedPdf.{Forms, PdfCheck}
  alias EmbedPdf.PDF.Document

  test "reads fields with their types, options and widgets" do
    fields = Forms.fields(open!("form-sample.pdf"))
    by_name = Map.new(fields, &{&1.name, &1})

    assert %{type: :text, max_len: 5} = by_name["maxlen_text"]
    assert %{type: :radio} = by_name["ntto_radio"]
    assert %{type: :checkbox} = by_name["opt_check"]
    assert %{type: :text} = by_name["billing.name"]
    # the duplicated entry in /Fields is listed once
    assert length(fields) == length(Enum.uniq_by(fields, & &1.id))
    assert Enum.all?(fields, fn f -> Enum.all?(f.widgets, &(&1.page == 0)) end)

    lists = Forms.fields(open!("form-listbox.pdf"))
    multi = Enum.find(lists, &(&1.name == "Listbox_MultiSelect"))
    assert multi.type == :list
    assert multi.multi_select?
    assert {"Apple", "Apple"} in multi.options
    assert Enum.find(lists, &(&1.name == "Listbox_ReadOnly")).read_only?
  end

  test "fills text fields and regenerates their appearance" do
    doc = open!("form-sample.pdf")
    doc = Forms.set_value(doc, "maxlen_text", "1234567")
    doc = Forms.set_value(doc, "billing.name", "Ana Pérez")
    again = PdfCheck.roundtrip!(doc, "form-text")

    assert Forms.get(again, "maxlen_text").value == "12345"
    assert Forms.get(again, "billing.name").value == "Ana Pérez"
    assert Document.get(again, Document.catalog(again), "AcroForm")["NeedAppearances"] == false

    # the appearance shows the value
    [w] = Forms.get(again, "billing.name").widgets
    ap = Document.get_in(again, {:ref, w.id, 0}, ["AP", "N"])

    shown =
      for {"Tj", [{:string, s}]} <- EmbedPdf.PDF.Content.parse(Document.stream_data(again, ap)),
          do: s

    assert shown == ["Ana P" <> <<0xE9>> <> "rez"]
  end

  test "check boxes and radio buttons switch appearance states" do
    doc = open!("form-sample.pdf")
    radio = Forms.get(doc, "ntto_radio")
    [{first, _} | _] = radio.options
    doc = doc |> Forms.set_value("opt_check", true) |> Forms.set_value("ntto_radio", first)

    again = PdfCheck.roundtrip!(doc, "form-buttons")
    assert Forms.get(again, "opt_check").value == true
    assert Forms.get(again, "ntto_radio").value == first
    checked = Forms.get(again, "ntto_radio").widgets |> Enum.filter(& &1.checked?)
    assert [%{on_state: ^first}] = checked

    doc = Forms.set_value(again, "opt_check", false)
    assert Forms.get(doc, "opt_check").value == false
  end

  test "list boxes select one or many" do
    doc = open!("form-listbox.pdf")

    doc =
      doc
      |> Forms.set_value("Listbox_MultiSelect", ["Banana", "Apple"])
      |> Forms.set_value("Listbox_SingleSelect", "Bar")

    again = PdfCheck.roundtrip!(doc, "form-list")
    assert Forms.get(again, "Listbox_MultiSelect").value == ["Apple", "Banana"]
    assert Forms.get(again, "Listbox_SingleSelect").value in ["bar", "Bar"]
  end

  test "reset restores defaults" do
    doc = open!("form-sample.pdf") |> Forms.set_value("maxlen_text", "999") |> Forms.reset()
    assert Forms.get(doc, "maxlen_text").value == ""
    PdfCheck.roundtrip!(doc, "form-reset")
  end

  test "larger form" do
    doc = open!("forms.pdf")
    fields = Forms.fields(doc)
    assert length(fields) > 5

    doc =
      Enum.reduce(fields, doc, fn f, d ->
        case f.type do
          :text -> Forms.set_value(d, f.id, "Value for #{f.name}")
          :checkbox -> Forms.set_value(d, f.id, true)
          :radio -> Forms.set_value(d, f.id, f.options |> hd() |> elem(0))
          :combo -> Forms.set_value(d, f.id, f.options |> hd() |> elem(0))
          :list -> Forms.set_value(d, f.id, f.options |> hd() |> elem(0))
          _ -> d
        end
      end)

    again = PdfCheck.roundtrip!(doc, "forms-all")
    text = Enum.find(Forms.fields(again), &(&1.type == :text))
    assert text.value == "Value for #{text.name}"
  end

  test "fonts embedded for a form without /Widths take their advances from the program" do
    doc = open!("kept_fonts_form.pdf")
    dr = Document.get(doc, Document.get(doc, Document.catalog(doc), "AcroForm"), "DR")
    fonts = Document.get(doc, dr, "Font")

    # a fixed-pitch CFF font: every glyph is 600 units wide
    fixed = EmbedPdf.Font.load(doc, fonts["FCff"])
    assert map_size(fixed.widths) > 90
    assert fixed.widths |> Map.values() |> Enum.uniq() == [0.6]

    # a Type 1 subset: widths come from each charstring's hsbw
    roboto = EmbedPdf.Font.load(doc, fonts["FT1"])
    assert_in_delta roboto.widths[?H], 0.734, 0.001
    assert_in_delta roboto.widths[?,], 0.202, 0.001
  end

  test "fields saved without an appearance are drawn in the font their form names" do
    doc = open!("kept_fonts_form.pdf")
    refute Enum.any?(Forms.fields(doc), fn f -> Enum.any?(f.widgets, & &1.on_state) end)

    with_ap = Forms.ensure_appearances(doc, 0)

    for field <- Forms.fields(with_ap), widget <- field.widgets do
      dict = Document.resolve(with_ap, {:ref, widget.id, 0})
      ap = Document.get(with_ap, Document.get(with_ap, dict, "AP"), "N")
      content = Document.stream_data(with_ap, ap)
      assert content =~ ~r{/(FCff|FT1) [\d.]+ Tf}
    end

    # the page image uses those outlines rather than a stand-in in Helvetica
    svg = doc |> EmbedPdf.render_svg(0) |> IO.iodata_to_binary()
    refute svg =~ "<text"
    assert svg =~ "<path" or svg =~ "<use"

    # the saved file still leaves those appearances to its reader
    {:ok, again} = EmbedPdf.open(EmbedPdf.save(doc))

    for field <- Forms.fields(again), widget <- field.widgets do
      refute Map.has_key?(Document.resolve(again, {:ref, widget.id, 0}), "AP")
    end
  end
end
