defmodule EmbedPdf.RedactionTest do
  use ExUnit.Case, async: true
  import EmbedPdf.TestHelpers

  alias EmbedPdf.{Annotations, PdfCheck, Redaction, Writer}
  alias EmbedPdf.PDF.{Document, Filter, Page, Stream}
  alias EmbedPdf.Render.{Interpreter, Matrix}

  defp hit_rects(doc, page, query) do
    pt = EmbedPdf.Text.page(doc, page)
    [hit | _] = EmbedPdf.Text.search(pt, query)
    Enum.map(hit.rects, &Page.rect_to_user(Document.page(doc, page), &1))
  end

  test "removes the text under the area and keeps the rest in place" do
    doc = open!("ebook.pdf")
    rects = hit_rects(doc, 1, "integration sucks")
    before = EmbedPdf.Text.page(doc, 1)
    red = Redaction.apply(doc, 1, rects, overlay_text: "REDACTED")

    text = EmbedPdf.text(red, 1)
    refute text =~ "sucks"
    refute text =~ "integration"
    assert text =~ "Let's face it"
    assert text =~ "You need PDF functionality"

    # untouched lines keep their boxes
    after_ = EmbedPdf.Text.page(red, 1)
    line = fn pt -> Enum.find(pt.lines, &String.starts_with?(&1.text, "You need")) end
    assert line.(before).box == line.(after_).box

    again = PdfCheck.roundtrip!(red, "redact-text")
    refute EmbedPdf.text(again, 1) =~ "sucks"
  end

  test "text in other pages is untouched" do
    doc = open!("ebook.pdf")
    red = Redaction.apply(doc, 1, hit_rects(doc, 1, "integration sucks"))
    assert EmbedPdf.text(red, 2) == EmbedPdf.text(doc, 2)
  end

  test "marked redactions are applied and removed" do
    doc = open!("ebook.pdf")
    [rect] = hit_rects(doc, 1, "integration sucks")

    {doc, _} =
      Annotations.add(doc, 1, %{
        subtype: :redact,
        quad_points: [rect],
        overlay_text: "Gone",
        interior_color: {0.2, 0.2, 0.2}
      })

    assert [_] = Redaction.pending(doc)

    doc = Redaction.apply_marked(doc)
    assert Redaction.pending(doc) == []
    refute EmbedPdf.text(doc, 1) =~ "sucks"
    PdfCheck.roundtrip!(doc, "redact-marked")
  end

  test "paints decodable images and drops the ones it cannot decode" do
    doc = open!("welcome.pdf")

    images =
      for page <- doc.pages,
          ev <-
            Interpreter.run_page(
              doc,
              page,
              fn
                {:image, %{image: %Stream{} = img, gs: gs}}, acc ->
                  [{page.index, img, gs.ctm} | acc]

                _, acc ->
                  acc
              end,
              [],
              text_only: false
            ),
          do: ev

    {index, img, ctm} =
      Enum.find(images, fn {_, %Stream{dict: d}, _} ->
        d["Filter"] == "FlateDecode" and d["ColorSpace"] == "DeviceRGB"
      end)

    {x0, y0, x1, y1} = Matrix.transform_rect(ctm, {0.0, 0.0, 1.0, 1.0})
    area = {x0, y0, x0 + (x1 - x0) / 2, y0 + (y1 - y0) / 2}
    red = Redaction.apply(doc, index, [area], fill: {0.0, 0.0, 0.0})

    new_images =
      Interpreter.run_page(
        red,
        Document.page(red, index),
        fn
          {:image, %{image: %Stream{} = i}}, acc -> [i | acc]
          _, acc -> acc
        end,
        [],
        text_only: false
      )

    refute Enum.any?(new_images, &(&1 == img))

    painted =
      Enum.find(
        new_images,
        &(&1.dict["Width"] == img.dict["Width"] and &1.dict["Height"] == img.dict["Height"])
      )

    assert painted
    data = Filter.decode!(painted.raw, painted.dict["Filter"], painted.dict["DecodeParms"])
    w = img.dict["Width"]
    h = img.dict["Height"]
    # bottom-left pixel is inside the area → black
    assert binary_part(data, ((h - 2) * w + 1) * 3, 3) == <<0, 0, 0>>
    # top-right pixel is outside → unchanged
    original = Filter.decode!(img.raw, img.dict["Filter"], img.dict["DecodeParms"])
    assert binary_part(data, (2 * w - 2) * 3, 3) == binary_part(original, (2 * w - 2) * 3, 3)

    PdfCheck.roundtrip!(red, "redact-image")
  end

  test "deletes annotations under the area" do
    doc = open!("welcome.pdf")
    {doc, a} = Annotations.add(doc, 0, %{subtype: :square, rect: {100, 100, 200, 200}})
    {doc, b} = Annotations.add(doc, 0, %{subtype: :square, rect: {400, 400, 450, 450}})
    red = Redaction.apply(doc, 0, [{150, 150, 160, 160}])
    refute Annotations.get(red, a.id)
    assert Annotations.get(red, b.id)
  end

  test "flattening bakes annotations into the page" do
    doc = open!("ebook-annotated.pdf")
    {doc, _} = Annotations.add(doc, 0, %{subtype: :stamp, icon: "draft", at: {300, 300}})
    flat = Writer.flatten_annotations(doc, :all)
    assert Annotations.list(flat, 0) == []
    content = Document.page_content(flat, Document.page(flat, 0))
    assert content =~ ~r/\/Fl\d+ Do/
    again = PdfCheck.roundtrip!(flat, "flatten")
    assert Annotations.list(again, 0) == []
  end

  test "writer stamps producer and mod date" do
    doc = open!("welcome.pdf")
    {:ok, again} = EmbedPdf.open(Writer.save(doc))
    meta = EmbedPdf.Metadata.get(again)
    assert meta.producer == "EmbedPdf"
    assert DateTime.diff(DateTime.utc_now(), meta.modified) < 60
    {:ok, plain} = EmbedPdf.open(Writer.save(doc, metadata: false))
    refute EmbedPdf.Metadata.get(plain).producer == "EmbedPdf"
  end
end
