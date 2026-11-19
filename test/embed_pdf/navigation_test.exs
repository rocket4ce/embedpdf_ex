defmodule EmbedPdf.NavigationTest do
  use ExUnit.Case, async: true
  import EmbedPdf.TestHelpers

  alias EmbedPdf.{Destinations, Links, Outline, PdfCheck}
  alias EmbedPdf.PDF.Document

  describe "links and destinations" do
    test "named destinations resolve to pages" do
      doc = open!("links.pdf")
      [first | _] = Links.list(doc, 0)
      assert {:goto, %{page: 1, fit: :xyz, top: 792.0}} = first.action

      assert %{page: 2, left: 60.0, top: 108.0, fit: :xyz} =
               Destinations.resolve(doc, "footnote-1")

      assert Destinations.resolve(doc, "no-such-name") == nil
    end

    test "uri links" do
      doc = open!("links.pdf")
      uris = for l <- Links.list(doc, 3), {:uri, u} <- [l.action], do: u
      assert "https://fonts.google.com/specimen/Manrope" in uris
    end

    test "adding a link and changing its target" do
      doc = open!("welcome.pdf")
      {doc, link} = Links.add(doc, 0, {72, 72, 200, 90}, {:page, 2})
      assert {:goto, %{page: 2}} = link.action
      {doc, _} = Links.set_target(doc, link.id, {:uri, "https://example.com"})
      again = PdfCheck.roundtrip!(doc, "links")
      assert Enum.any?(Links.list(again, 0), &(&1.action == {:uri, "https://example.com"}))
    end

    test "actions" do
      doc = open!("links.pdf")

      assert Destinations.action(doc, %{"S" => "Named", "N" => "NextPage"}) ==
               {:named, "NextPage"}

      assert {:uri, "https://x.y"} =
               Destinations.action(doc, %{"S" => "URI", "URI" => {:string, "https://x.y"}})

      assert {:goto, %{page: 0}} =
               Destinations.action(doc, %{
                 "S" => "GoTo",
                 "D" => [Document.page(doc, 0).ref, "Fit"]
               })
    end
  end

  describe "outline" do
    test "reads the tree" do
      tree = Outline.tree(open!("links.pdf"))
      assert ["Contents", "Logo", "Colour" | _] = Enum.map(tree, & &1.title)
      assert Enum.all?(tree, &match?(%{dest: %{page: _}}, &1))
    end

    test "adds, nests, renames, moves and deletes items consistently" do
      doc = open!("links.pdf")
      [contents, logo | _] = Outline.tree(doc)

      {doc, a} = Outline.add(doc, nil, "Appendix", 3, bold: true)
      {doc, b} = Outline.add(doc, a, "Child", 2)
      doc = Outline.rename(doc, b, "Renamed child")
      doc = Outline.set_open(doc, a, true)

      tree = Outline.tree(doc)
      appendix = List.last(tree)
      assert appendix.title == "Appendix"
      assert appendix.bold?
      assert appendix.open?
      assert [%{title: "Renamed child", dest: %{page: 2}}] = appendix.children

      doc = Outline.move(doc, logo.id, :up)
      assert [%{id: id1}, %{id: id2} | _] = Outline.tree(doc)
      assert {id1, id2} == {logo.id, contents.id}

      doc = Outline.move(doc, contents.id, :indent)
      [first | _] = Outline.tree(doc)
      assert [%{id: c}] = first.children
      assert c == contents.id

      doc = Outline.move(doc, contents.id, :outdent)
      assert [%{id: _}, %{id: second} | _] = Outline.tree(doc)
      assert second == contents.id

      doc = Outline.delete(doc, a)
      refute Enum.any?(Outline.tree(doc), &(&1.title == "Appendix"))

      again = PdfCheck.roundtrip!(doc, "outline")
      assert length(Outline.tree(again)) == length(Outline.tree(doc))
      check_counts(again)
    end

    test "creates an outline in a document without one" do
      doc = open!("welcome.pdf")
      doc = Enum.reduce(Outline.tree(doc), doc, &Outline.delete(&2, &1.id))
      {doc, _} = Outline.add(doc, nil, "Start", 0)
      again = PdfCheck.roundtrip!(doc, "new-outline")
      assert [%{title: "Start", dest: %{page: 0}}] = Outline.tree(again)
    end
  end

  # /Count of the root is the number of visible items
  defp check_counts(doc) do
    root = Document.get(doc, Document.catalog(doc), "Outlines")

    visible = fn visible, items ->
      Enum.reduce(items, 0, fn i, acc ->
        acc + 1 + if(i.open?, do: visible.(visible, i.children), else: 0)
      end)
    end

    assert root["Count"] == visible.(visible, Outline.tree(doc))
  end
end
