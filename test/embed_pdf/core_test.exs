defmodule EmbedPdf.CoreTest do
  use ExUnit.Case, async: true
  import EmbedPdf.TestHelpers

  alias EmbedPdf.PDF.{Content, Document, Filter, Page, Parser, Serializer}

  describe "parser" do
    test "parses the basic object types" do
      assert {%{"Type" => "Page", "Count" => 3, "Kids" => [{:ref, 4, 0}, {:ref, 5, 0}]}, _} =
               Parser.parse_value("<< /Type /Page /Count 3 /Kids [4 0 R 5 0 R] >>")

      assert {{:string, "a(b)c\n"}, _} = Parser.parse_value("(a\\(b\\)c\\n)")
      assert {{:string, "Hi"}, _} = Parser.parse_value("<4869>")
      assert {{:string, <<0x70>>}, _} = Parser.parse_value("<7>")
      assert {"A B", _} = Parser.parse_value("/A#20B")
      assert {-0.5, _} = Parser.parse_value("-.5")
      assert {[1, 2.5, true, nil], _} = Parser.parse_value("[1 2.5 true null]")
    end

    test "nested parentheses and octal escapes" do
      assert {{:string, "(x)A"}, _} = Parser.parse_value("((x)\\101)")
    end

    test "content streams with inline images" do
      ops = Content.parse("q 1 0 0 1 0 0 cm BI /W 2 /H 1 /BPC 8 /CS /G ID \x01\x02 EI Q")

      assert [{"q", []}, {"cm", _}, {"BI", [%{dict: %{"Width" => 2}, data: <<1, 2>>}]}, {"Q", []}] =
               ops
    end
  end

  describe "filters" do
    test "flate with PNG up predictor" do
      raw = <<2, 1, 2, 2, 1, 1>>
      data = :zlib.compress(raw)

      assert Filter.decode!(data, "FlateDecode", %{"Predictor" => 12, "Columns" => 2}) ==
               <<1, 2, 2, 3>>
    end

    test "ascii85 and asciihex" do
      assert Filter.decode!("87cURD]i,\"Ebo80~>", "ASCII85Decode", nil) == "Hello World!"
      assert Filter.decode!("48 65 6C6C6F>", "ASCIIHexDecode", nil) == "Hello"
    end

    test "run length" do
      assert Filter.decode!(<<2, ?a, ?b, ?c, 254, ?z, 128>>, "RunLengthDecode", nil) == "abczzz"
    end
  end

  describe "documents" do
    test "opens every fixture" do
      for name <-
            ~w(welcome.pdf ebook.pdf links.pdf forms.pdf sketch.pdf mixed_page_sizes_test.pdf) do
        doc = open!(name)
        assert EmbedPdf.page_count(doc) > 0
      end
    end

    test "page sizes and rotation" do
      doc = open!("mixed_page_sizes_test.pdf")
      assert EmbedPdf.page_count(doc) == 8
      sizes = for i <- 0..7, do: EmbedPdf.page_size(doc, i)
      assert length(Enum.uniq(sizes)) > 1
    end

    test "encrypted documents need the password" do
      data = File.read!(fixture("demo_protected.pdf"))
      assert {:error, :password_required} = EmbedPdf.open(data)
      assert {:error, :bad_password} = EmbedPdf.open(data, password: "nope")
      assert {:ok, doc} = EmbedPdf.open(data, password: "embedpdf")
      assert EmbedPdf.text(doc, 0) =~ ~r/\w+/
    end

    test "save round-trips" do
      doc = open!("welcome.pdf")
      bytes = Serializer.save(doc)
      assert {:ok, again} = EmbedPdf.open(bytes)
      assert EmbedPdf.page_count(again) == EmbedPdf.page_count(doc)
      assert EmbedPdf.text(again, 0) == EmbedPdf.text(doc, 0)
    end

    test "decrypted documents save unencrypted" do
      {:ok, doc} = EmbedPdf.open(File.read!(fixture("demo_protected.pdf")), password: "embedpdf")
      {:ok, again} = EmbedPdf.open(Serializer.save(doc))
      assert again.crypt == nil
      assert EmbedPdf.text(again, 0) == EmbedPdf.text(doc, 0)
    end

    test "coordinate conversion round-trips for every rotation" do
      doc = open!("welcome.pdf")
      page = Document.page(doc, 0)

      for rot <- [0, 90, 180, 270] do
        {x, y} = Page.to_display(page, {100, 200}, rot)
        {ux, uy} = Page.to_user(page, {x, y}, rot)
        assert_in_delta ux, 100, 0.001
        assert_in_delta uy, 200, 0.001
      end
    end
  end

  describe "text" do
    test "extracts lines and searches" do
      doc = open!("ebook.pdf")
      assert EmbedPdf.text(doc, 1) =~ "integration sucks."
      hits = EmbedPdf.search(doc, "PDF SDK")
      assert hits != []
      assert Enum.all?(hits, &(&1.rects != []))
    end

    test "whole word and case options" do
      pt = EmbedPdf.Text.page(open!("ebook.pdf"), 1)
      assert EmbedPdf.Text.search(pt, "pdf", case_sensitive: true) == []
      assert EmbedPdf.Text.search(pt, "pdf") != []
      assert EmbedPdf.Text.search(pt, "integ", whole_word: true) == []
    end

    test "ligature glyphs read as their letters" do
      doc = open!("demo_protected.pdf", password: "embedpdf")
      text = EmbedPdf.text(doc, 0)
      refute text =~ "\uFB01"
      assert text =~ "identifies"
      assert length(EmbedPdf.search(doc, "efficient")) == 18
      assert EmbedPdf.search(doc, "e\uFB03cient") == EmbedPdf.search(doc, "efficient")
    end

    test "typographic and keyboard quotes match each other" do
      pt = EmbedPdf.Text.page(open!("ebook-annotated.pdf"), 0)
      assert [%{text: found}] = EmbedPdf.Text.search(pt, "don't have")
      assert found =~ "Don"
      assert EmbedPdf.Text.search(pt, "don\u2019t have") != []
    end
  end

  describe "saving" do
    test "small real numbers keep their value" do
      alias EmbedPdf.PDF.Serializer

      assert Serializer.serialize(4.8828125e-4) |> IO.iodata_to_binary() == "0.00048828125"
      assert Serializer.serialize(-4.8828125e-4) |> IO.iodata_to_binary() == "-0.00048828125"
      assert Serializer.serialize(0.23999999) |> IO.iodata_to_binary() == "0.23999999"
      assert Serializer.serialize(3.0) |> IO.iodata_to_binary() == "3"

      assert Serializer.serialize(1.0e-7) |> IO.iodata_to_binary() |> Float.parse() ==
               {1.0e-7, ""}
    end

    test "a Type 3 font matrix survives a save" do
      doc = open!("ebook-annotated.pdf")
      {:ok, again} = EmbedPdf.open(EmbedPdf.save(doc))

      matrices = fn d ->
        for {_n, %{"Subtype" => "Type3", "FontMatrix" => m}} <- d.objects, do: m
      end

      assert matrices.(doc) != []
      assert Enum.sort(matrices.(again)) == Enum.sort(matrices.(doc))
    end
  end
end
