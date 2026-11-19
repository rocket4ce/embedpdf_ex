defmodule EmbedPdf.AnnotationsTest do
  use ExUnit.Case, async: true
  import EmbedPdf.TestHelpers

  alias EmbedPdf.{Annotation, Annotations, PdfCheck, Stamps}
  alias EmbedPdf.PDF.{Document, Stream}

  describe "reading" do
    test "lists the annotations of a page with their geometry" do
      doc = open!("ebook-annotated.pdf")
      annots = Annotations.list(doc, 0)
      subtypes = annots |> Enum.map(& &1.subtype) |> MapSet.new()

      assert MapSet.subset?(MapSet.new([:highlight, :circle, :line, :ink]), subtypes)
      refute :popup in subtypes

      hl = Enum.find(annots, &(&1.subtype == :highlight))
      assert [{_, _, _, _} | _] = hl.quad_points
      assert {r, _, _} = hl.color
      assert r > 0.9

      ink = Enum.find(annots, &(&1.subtype == :ink))
      assert [[{_, _} | _] | _] = ink.ink_list
      assert ink.border_width == 7.0

      line = Enum.find(annots, &(&1.subtype == :line))
      assert {_, _, _, _} = line.line
    end

    test "get finds one annotation and its page" do
      doc = open!("ebook-annotated.pdf")
      [first | _] = Annotations.list(doc, 0)
      assert %Annotation{page: 0} = Annotations.get(doc, first.id)
      assert Annotations.page_of(doc, first.id) == 0
      assert Annotations.get(doc, 999_999) == nil
    end
  end

  describe "creating" do
    setup do
      {:ok, doc: open!("welcome.pdf")}
    end

    test "every creatable subtype gets an appearance and survives a save", %{doc: doc} do
      specs = [
        %{subtype: :highlight, quad_points: [{72, 700, 300, 714}, {72, 680, 200, 694}]},
        %{subtype: :underline, quad_points: [{72, 650, 300, 664}]},
        %{subtype: :strikeout, quad_points: [{72, 630, 300, 644}]},
        %{subtype: :squiggly, quad_points: [{72, 610, 300, 624}]},
        %{subtype: :ink, ink_list: [[{100, 400}, {120, 420}, {150, 410}], [{160, 400}]]},
        %{subtype: :square, rect: {50, 50, 150, 90}, interior_color: {0.9, 0.9, 1.0}},
        %{subtype: :circle, rect: {200, 50, 260, 90}, border_style: :dashed},
        %{subtype: :line, line: {100, 100, 250, 200}, line_endings: {:circle, :closed_arrow}},
        %{subtype: :polygon, vertices: [{300, 500}, {350, 560}, {400, 500}]},
        %{
          subtype: :polyline,
          vertices: [{300, 400}, {350, 460}, {400, 400}],
          line_endings: {:none, :open_arrow}
        },
        %{
          subtype: :free_text,
          rect: {300, 100, 500, 180},
          contents: "Hello world, this text wraps over several lines.",
          text_align: :center,
          font_family: :times
        },
        %{subtype: :text, at: {500, 750}, contents: "A note", author: "Ana"},
        %{subtype: :stamp, icon: "confidential", at: {300, 300}, rotation: 30},
        %{subtype: :stamp, icon: "accepted", at: {100, 300}},
        %{subtype: :redact, quad_points: [{72, 500, 150, 512}], overlay_text: "X"},
        %{subtype: :caret, at: {420, 600}},
        %{subtype: :file_attachment, at: {40, 760}, file: %{name: "notes.txt", data: "hello"}},
        %{subtype: :link, rect: {72, 72, 200, 90}}
      ]

      doc =
        Enum.reduce(specs, doc, fn spec, d ->
          {d, a} = Annotations.add(d, 0, spec)
          assert a.subtype == spec.subtype
          assert {_, _, _, _} = a.rect
          assert a.has_appearance?, "#{spec.subtype} has no appearance"
          assert %Stream{dict: %{"Subtype" => "Form"}} = Annotations.appearance(d, a.id)
          d
        end)

      again = PdfCheck.roundtrip!(doc, "annots")
      created = Annotations.list(again, 0) |> Enum.map(& &1.subtype)
      for spec <- specs, do: assert(spec.subtype in created)

      ft = Enum.find(Annotations.list(again, 0), &(&1.subtype == :free_text))
      assert ft.font_family == :times
      assert ft.text_align == :center
      assert ft.font_size == 14.0

      stamp =
        Enum.find(
          Annotations.list(again, 0),
          &(&1.subtype == :stamp and &1.icon == "Confidential")
        )

      assert stamp.rotation == 30
      assert stamp.subject == "Confidential"
    end

    test "rect is derived from the geometry", %{doc: doc} do
      {_doc, a} =
        Annotations.add(doc, 0, %{
          subtype: :highlight,
          quad_points: [{10, 10, 50, 20}, {10, 30, 80, 40}]
        })

      assert a.rect == {10.0, 10.0, 80.0, 40.0}

      {_doc, ink} =
        Annotations.add(doc, 0, %{
          subtype: :ink,
          border_width: 2.0,
          ink_list: [[{10, 10}, {20, 30}]]
        })

      {x0, y0, x1, y1} = ink.rect
      assert x0 < 10 and y0 < 10 and x1 > 20 and y1 > 30
    end

    test "stamps placed at a point take the library size", %{doc: doc} do
      {_doc, a} = Annotations.add(doc, 0, %{subtype: :stamp, icon: "approved", at: {300, 300}})
      {x0, y0, x1, y1} = a.rect
      {w, h} = Stamps.get("approved").size
      assert_in_delta x1 - x0, w, 0.01
      assert_in_delta y1 - y0, h, 0.01
      assert_in_delta (x0 + x1) / 2, 300, 0.01
      assert a.icon == "Approved"
    end
  end

  describe "changing" do
    setup do
      doc = open!("welcome.pdf")
      {doc, a} = Annotations.add(doc, 0, %{subtype: :square, rect: {100, 100, 200, 150}})
      {:ok, doc: doc, id: a.id}
    end

    test "update changes fields and the appearance", %{doc: doc, id: id} do
      before = Annotations.appearance(doc, id)

      {doc, a} =
        Annotations.update(doc, id, %{color: {0.0, 0.0, 1.0}, contents: "Blue", opacity: 0.5})

      assert a.color == {0.0, 0.0, 1.0}
      assert a.contents == "Blue"
      assert a.opacity == 0.5
      refute Annotations.appearance(doc, id).raw == before.raw
      assert %{"ExtGState" => _} = Annotations.appearance(doc, id).dict["Resources"]
    end

    test "move and resize transform the geometry", %{doc: doc, id: id} do
      {doc, a} = Annotations.move(doc, id, 10, -5)
      assert a.rect == {110.0, 95.0, 210.0, 145.0}
      {_doc, a} = Annotations.resize(doc, id, {0, 0, 50, 25})
      assert a.rect == {0.0, 0.0, 50.0, 25.0}

      {doc, ink} =
        Annotations.add(doc, 0, %{
          subtype: :ink,
          ink_list: [[{0, 0}, {10, 10}]],
          border_width: 2.0
        })

      {_doc, moved} = Annotations.move(doc, ink.id, 5, 5)
      assert [[{5.0, 5.0}, {15.0, 15.0}]] = moved.ink_list
    end

    test "duplicate makes an offset copy", %{doc: doc, id: id} do
      {doc, copy} = Annotations.duplicate(doc, id)
      refute copy.id == id
      assert copy.rect == {110.0, 90.0, 210.0, 140.0}
      assert length(Annotations.list(doc, 0)) == 2
    end

    test "replies nest under their parent and go with it", %{doc: doc, id: id} do
      {doc, r1} = Annotations.reply(doc, id, "First", "Ana")
      {doc, _r2} = Annotations.reply(doc, r1.id, "Second", "Luis")
      [parent] = Annotations.list(doc, 0)

      assert [%{contents: "First", author: "Ana", replies: [%{contents: "Second"}]}] =
               parent.replies

      again = PdfCheck.roundtrip!(doc, "replies")
      [p] = Annotations.list(again, 0)
      assert [%{replies: [_]}] = p.replies

      doc = Annotations.delete(doc, id)
      assert Annotations.list(doc, 0) == []
      assert Document.resolve(doc, {:ref, r1.id, 0}) == nil
    end

    test "deleting removes the popup too" do
      doc = open!("ebook-annotated.pdf")
      with_popup = Enum.find(Annotations.list(doc, 0), & &1.popup)

      if with_popup do
        doc = Annotations.delete(doc, with_popup.id)
        refute Annotations.get(doc, with_popup.id)
        refute Document.resolve(doc, {:ref, with_popup.popup, 0})
      end

      PdfCheck.roundtrip!(doc, "delete")
    end
  end

  test "stamp library" do
    assert length(Stamps.list()) == 17
    assert Stamps.get("not-approved").label == "Not Approved"
    assert Stamps.get("NotApproved").id == "not-approved"
    assert Stamps.get("sign here").name == "SignHere"
    assert Stamps.get("nope") == nil
  end
end
