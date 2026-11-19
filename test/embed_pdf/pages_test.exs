defmodule EmbedPdf.PagesTest do
  use ExUnit.Case, async: true
  import EmbedPdf.TestHelpers

  alias EmbedPdf.{Annotations, Attachments, Links, Metadata, Outline, Pages, PdfCheck}
  alias EmbedPdf.PDF.{Document, NameTree}

  defp texts(doc), do: Enum.map(doc.pages, &EmbedPdf.text(doc, &1.index))

  describe "pages" do
    test "rotate" do
      doc = open!("ebook.pdf")
      doc = Pages.rotate(doc, [0, 2], 90)
      assert Enum.map(doc.pages, & &1.rotate) == [90, 0, 90, 0]
      doc = Pages.rotate(doc, 0, -180)
      assert Document.page(doc, 0).rotate == 270
      again = PdfCheck.roundtrip!(doc, "rotate")
      assert Enum.map(again.pages, & &1.rotate) == [270, 0, 90, 0]
    end

    test "delete keeps the tree valid and drops dangling bookmarks and links" do
      doc = open!("links.pdf")
      original = texts(doc)
      outline_before = length(Outline.tree(doc))
      doc = Pages.delete(doc, [1])

      assert EmbedPdf.page_count(doc) == 3
      assert texts(doc) == List.delete_at(original, 1)
      assert length(Outline.tree(doc)) == outline_before - 1

      for i <- 0..2, l <- Links.list(doc, i) do
        refute match?({:goto, %{page: nil}}, l.action)
      end

      again = PdfCheck.roundtrip!(doc, "delete")
      assert EmbedPdf.page_count(again) == 3
      assert_raise ArgumentError, fn -> Pages.delete(doc, [0, 1, 2]) end
    end

    test "move reorders pages" do
      doc = open!("ebook.pdf")
      [a, b, c, d] = texts(doc)
      moved = Pages.move(doc, [2, 3], 0)
      assert texts(moved) == [c, d, a, b]
      moved = Pages.move(doc, [0], 3)
      assert texts(moved) == [b, c, d, a]
      PdfCheck.roundtrip!(moved, "move")
    end

    test "duplicate copies a page with its annotations" do
      doc = open!("ebook-annotated.pdf")
      n = length(Annotations.list(doc, 0))
      doc = Pages.duplicate(doc, 0)
      assert EmbedPdf.page_count(doc) == 5
      assert EmbedPdf.text(doc, 1) == EmbedPdf.text(doc, 0)
      copies = Annotations.list(doc, 1)
      assert length(copies) == n
      assert Enum.all?(copies, fn a -> Annotations.page_of(doc, a.id) == 1 end)
      PdfCheck.roundtrip!(doc, "duplicate")
    end

    test "insert blank pages" do
      doc = open!("ebook.pdf") |> Pages.insert_blank(1, {300, 400}) |> Pages.insert_blank(99)
      assert EmbedPdf.page_count(doc) == 6
      assert EmbedPdf.page_size(doc, 1) == {300.0, 400.0}
      assert EmbedPdf.page_size(doc, 5) == {612.0, 792.0}
      assert EmbedPdf.text(doc, 1) == ""
      PdfCheck.roundtrip!(doc, "blank")
    end

    test "insert pages from another document" do
      doc = open!("ebook.pdf")
      other = open!("links.pdf")
      merged = Pages.insert_document(doc, 1, other, [0, 2])
      assert EmbedPdf.page_count(merged) == 6
      assert EmbedPdf.text(merged, 1) == EmbedPdf.text(other, 0)
      assert EmbedPdf.text(merged, 2) == EmbedPdf.text(other, 2)
      assert EmbedPdf.text(merged, 3) == EmbedPdf.text(doc, 1)

      # a link from copied page 0 to copied page 2 still works; links to pages
      # not copied lead nowhere
      targets = for l <- Links.list(merged, 1), {:goto, %{page: p}} <- [l.action], do: p
      assert 2 in targets

      again = PdfCheck.roundtrip!(merged, "merge")
      assert EmbedPdf.page_count(again) == 6
    end

    test "insert a document with form fields merges the fields" do
      doc = open!("ebook.pdf")
      merged = Pages.insert_document(doc, 0, open!("form-sample.pdf"))
      assert length(EmbedPdf.Forms.fields(merged)) >= 4
      PdfCheck.roundtrip!(merged, "merge-forms")
    end

    test "extract" do
      doc = open!("ebook.pdf")
      [_a, b, _c, d] = texts(doc)
      part = Pages.extract(doc, [3, 1])
      assert texts(part) == [d, b]
      again = PdfCheck.roundtrip!(part, "extract")
      assert byte_size(EmbedPdf.save(part)) < byte_size(EmbedPdf.save(doc))
      assert EmbedPdf.page_count(again) == 2
    end
  end

  describe "attachments" do
    test "add, list, read and delete" do
      doc = open!("welcome.pdf")
      assert Attachments.list(doc) == []
      {doc, id} = Attachments.add(doc, "report.csv", "a,b\n1,2\n", description: "Numbers")
      {doc, _} = Attachments.add(doc, "report.csv", "again")

      {doc, ann} =
        Annotations.add(doc, 0, %{
          subtype: :file_attachment,
          at: {50, 700},
          file: %{name: "note.txt", data: "hi"}
        })

      again = PdfCheck.roundtrip!(doc, "attachments")
      list = Attachments.list(again)
      assert length(list) == 3
      csv = Enum.find(list, &(&1.description == "Numbers"))
      assert %{name: "report.csv", size: 8, source: :document} = csv
      assert Attachments.data(again, csv.id) == "a,b\n1,2\n"
      assert Enum.any?(list, &match?(%{name: "note.txt", source: {:annotation, _}}, &1))

      doc = Attachments.delete(doc, id)
      assert length(Attachments.list(doc)) == 2
      note = Enum.find(Attachments.list(doc), &(&1.name == "note.txt"))
      doc = Attachments.delete(doc, note.id)
      refute Annotations.get(doc, ann.id)
      assert [%{name: "report.csv"}] = Attachments.list(doc)
    end
  end

  describe "metadata" do
    test "reads and writes the info dictionary" do
      doc = open!("links.pdf")
      assert %{title: "Brand guidelines", author: "Fernquill Ltd"} = Metadata.get(doc)
      dt = ~U[2024-05-06 07:08:09Z]

      doc =
        Metadata.put(doc,
          title: "Nuevo título ✓",
          author: nil,
          created: dt,
          custom: %{"Project" => "Alpha"}
        )

      again = PdfCheck.roundtrip!(doc, "metadata")
      meta = Metadata.get(again)
      assert meta.title == "Nuevo título ✓"
      assert meta.author == nil
      assert meta.created == dt
      assert meta.custom["Project"] == "Alpha"
      assert meta.producer == "EmbedPdf"
    end

    test "page labels" do
      doc = open!("ebook.pdf")
      assert Metadata.page_labels(doc) == ["1", "2", "3", "4"]

      labels = %{
        "Nums" => [0, %{"S" => "r"}, 2, %{"S" => "D", "P" => {:string, "A-"}, "St" => 5}]
      }

      catalog = Document.catalog(doc) |> Map.put("PageLabels", labels)
      doc = Document.put_object(doc, doc.trailer["Root"], catalog)
      assert Metadata.page_labels(doc) == ["i", "ii", "A-5", "A-6"]
      assert NameTree.number_entries(doc, labels) |> length() == 2
    end
  end
end
