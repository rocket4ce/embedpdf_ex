defmodule EmbedPdf.HostileRenderTest do
  # Small files that ask for unbounded work: each must come back quickly,
  # with what could be drawn. Not async: some tests lower the limits, which
  # are application settings.
  use ExUnit.Case, async: false

  alias EmbedPdf.PDF.Document
  alias EmbedPdf.Render.{CCITT, PostScript, SVG}
  alias EmbedPdf.Render.Function, as: Fun

  @placeholder ~s(fill="#e6e6e6")

  # ---------------------------------------------------------------- helpers

  # A classic PDF from `[{number, body}]`.
  defp pdf(objects) do
    {body, offsets} =
      Enum.reduce(objects, {"%PDF-1.7\n", %{}}, fn {n, b}, {acc, offsets} ->
        {acc <> "#{n} 0 obj\n" <> b <> "\nendobj\n", Map.put(offsets, n, byte_size(acc))}
      end)

    max = objects |> Enum.map(&elem(&1, 0)) |> Enum.max()

    entries =
      for i <- 0..max do
        case offsets[i] do
          nil -> "0000000000 65535 f \n"
          at -> String.pad_leading(Integer.to_string(at), 10, "0") <> " 00000 n \n"
        end
      end

    body <>
      "xref\n0 #{max + 1}\n" <>
      Enum.join(entries) <>
      "trailer\n<</Size #{max + 1} /Root 1 0 R>>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end

  defp stream(dict, data),
    do: "<<#{dict} /Length #{byte_size(data)}>>\nstream\n" <> data <> "\nendstream"

  # One page: content, the inside of its resource dictionary, more objects
  # (numbered from 10) and more page entries.
  defp page(content, resources \\ "", extra \\ [], page_entries \\ "") do
    doc =
      pdf(
        [
          {1, "<</Type/Catalog /Pages 2 0 R>>"},
          {2, "<</Type/Pages /Kids [3 0 R] /Count 1>>"},
          {3,
           "<</Type/Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R " <>
             "/Resources <<#{resources}>> #{page_entries}>>"},
          {4, stream("", content)}
        ] ++ extra
      )

    {:ok, doc} = Document.open(doc)
    doc
  end

  defp form(dict, content),
    do: stream("/Type/XObject /Subtype/Form /BBox [0 0 200 200] " <> dict, content)

  # Forms `first..`, each drawing the next `times` times; the last one runs `leaf`.
  defp forms(first, levels, times, leaf) do
    for i <- 0..(levels - 1) do
      if i == levels - 1 do
        {first + i, form("", leaf)}
      else
        {first + i,
         form(
           "/Resources <</XObject <</X #{first + i + 1} 0 R>>>>",
           String.duplicate("/X Do ", times)
         )}
      end
    end
  end

  defp image(dict, data \\ ""), do: stream("/Type/XObject /Subtype/Image " <> dict, data)

  defp image_page(objects),
    do: page("q 100 0 0 100 0 0 cm /I Do Q", "/XObject <</I 10 0 R>>", objects)

  defp svg(doc), do: doc |> SVG.render_page(0) |> IO.iodata_to_binary()

  defp count(string, part), do: length(String.split(string, part)) - 1

  # Runs `fun` in a process of its own and gives it five seconds.
  defp quickly(fun) do
    task = Task.async(fun)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> flunk("still running after 5 seconds")
    end
  end

  defp limit(key, value) do
    Application.put_env(:embedpdf_ex, key, value)
    on_exit(fn -> Application.delete_env(:embedpdf_ex, key) end)
  end

  @separation "/ColorSpace <</CS0 [/Separation /Spot /DeviceGray 10 0 R]>>"
  @spot_fill "/CS0 cs 0.5 scn 0 0 10 10 re f"

  # ---------------------------------------------------------------- functions (10, 34)

  describe "functions" do
    test "a stitching function that contains itself" do
      doc =
        page(@spot_fill, @separation, [
          {10, "<</FunctionType 3 /Domain [0 1] /Functions [10 0 R] /Bounds [] /Encode [0 1]>>"}
        ])

      assert quickly(fn -> svg(doc) end) =~ "<path"
    end

    test "an array of functions that contains itself" do
      doc = page(@spot_fill, @separation, [{10, "[10 0 R 10 0 R]"}])
      assert quickly(fn -> svg(doc) end) =~ "<path"
    end

    test "arrays sharing one child fifty times a level" do
      shared =
        for i <- 0..8 do
          {10 + i, "[" <> String.duplicate("#{11 + i} 0 R ", 50) <> "]"}
        end

      leaf = {19, "<</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1>>"}
      doc = page(@spot_fill, @separation, shared ++ [leaf])

      assert quickly(fn -> svg(doc) end) =~ "<path"
      # 50^9 leaves asked for: no more than the limit are kept
      parsed = quickly(fn -> Fun.parse(doc, {:ref, 10, 0}) end)
      assert Fun.cost(parsed) < 100_000
    end

    test "a function within the limits is parsed whole" do
      doc =
        page("", "", [
          {10,
           "<</FunctionType 3 /Domain [0 1] /Functions [11 0 R 11 0 R] /Bounds [0.5] /Encode [0 1 1 0]>>"},
          {11, "<</FunctionType 2 /Domain [0 1] /C0 [0 0] /C1 [1 0.5] /N 1>>"}
        ])

      func = Fun.parse(doc, {:ref, 10, 0})
      assert {:stitch, _, _, [{:exp, _, _, _, _, _}, {:exp, _, _, _, _, _}], [0.5], _} = func
      assert Fun.eval(func, [0.25]) == [0.5, 0.25]
      assert Fun.eval(func, [0.75]) == [0.5, 0.25]
    end
  end

  # ---------------------------------------------------------------- work budget (12)

  describe "the work budget" do
    setup do
      limit(:max_page_operators, 100_000)
    end

    test "forms that draw each other ten times over, nine deep" do
      doc = page("/X Do", "/XObject <</X 10 0 R>>", forms(10, 9, 10, "0 0 1 1 re f"))

      out = quickly(fn -> svg(doc) end)
      # a billion squares asked for: some are drawn, within the budget
      assert count(out, "<path") in 1..100_000
      assert quickly(fn -> EmbedPdf.Text.page(doc, 0).text end) == ""
    end

    test "Type 3 glyphs that show text in their own font" do
      text = "(" <> String.duplicate("a", 10) <> ") Tj"

      doc =
        page("BT /F1 12 Tf #{text} ET", "/Font <</F1 10 0 R>>", [
          {10,
           "<</Type/Font /Subtype/Type3 /FontBBox [0 0 1 1] /FontMatrix [1 0 0 1 0 0] " <>
             "/CharProcs <</a 11 0 R>> /Encoding <</Type/Encoding /Differences [97 /a]>> " <>
             "/FirstChar 97 /LastChar 97 /Widths [1] /Resources <</Font <</F1 10 0 R>>>>>>"},
          {11, stream("", "1 0 d0 0 0 1 1 re f BT /F1 1 Tf #{text} ET")}
        ])

      assert is_binary(quickly(fn -> svg(doc) end))
    end

    test "a soft mask, a pattern and an appearance draw on the page's budget" do
      fan_out = forms(20, 9, 10, "0 0 1 1 re f")
      to_fan_out = "/Resources <</XObject <</X 20 0 R>>>>"

      mask =
        page(
          "/GS0 gs 0 0 50 50 re f",
          "/ExtGState <</GS0 <</SMask <</S /Luminosity /G 10 0 R>>>>>>",
          [{10, form("/Group <</S /Transparency>> " <> to_fan_out, "/X Do")} | fan_out]
        )

      pattern =
        page(
          "/Pattern cs /P0 scn 0 0 50 50 re f",
          "/Pattern <</P0 10 0 R>>",
          [
            {10,
             stream(
               "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 " <>
                 to_fan_out,
               "/X Do"
             )}
            | fan_out
          ]
        )

      annotation =
        page(
          "",
          "",
          [
            {10, "<</Type/Annot /Subtype/Square /Rect [0 0 50 50] /AP <</N 11 0 R>>>>"},
            {11, form(to_fan_out, "/X Do")} | fan_out
          ],
          "/Annots [10 0 R]"
        )

      for doc <- [mask, pattern, annotation] do
        assert count(quickly(fn -> svg(doc) end), "<path") in 1..100_000
      end
    end

    test "an appearance gets what the page left" do
      appearance = [
        {10, "<</Type/Annot /Subtype/Square /Rect [0 0 50 50] /AP <</N 11 0 R>>>>"},
        {11, form("", "0 1 0 rg 0 0 5 5 re f")}
      ]

      spent =
        page(
          "/X Do",
          "/XObject <</X 20 0 R>>",
          appearance ++ forms(20, 9, 10, "0 0 1 1 re f"),
          "/Annots [10 0 R]"
        )

      left = page("0 0 1 1 re f", "", appearance, "/Annots [10 0 R]")

      refute quickly(fn -> svg(spent) end) =~ "#00ff00"
      assert quickly(fn -> svg(left) end) =~ "#00ff00"
    end

    test "a pattern starts at the depth it is used at" do
      # the pattern's cell draws through ten nested forms
      cell = [
        {10,
         stream(
           "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 " <>
             "/Resources <</XObject <</X 20 0 R>>>>",
           "/X Do"
         )}
        | forms(20, 10, 1, "1 0 0 rg 0 0 5 5 re f")
      ]

      fill = "/Pattern cs /P0 scn 0 0 50 50 re f"
      shallow = page(fill, "/Pattern <</P0 10 0 R>>", cell)

      # the same fill, five forms down
      deep =
        page(
          "/X Do",
          "/XObject <</X 40 0 R>>",
          cell ++
            for i <- 0..4 do
              if i == 4,
                do: {40 + i, form("/Resources <</Pattern <</P0 10 0 R>>>>", fill)},
                else: {40 + i, form("/Resources <</XObject <</X #{41 + i} 0 R>>>>", "/X Do")}
            end
        )

      assert quickly(fn -> svg(shallow) end) =~ "#ff0000"
      refute quickly(fn -> svg(deep) end) =~ "#ff0000"
    end

    test "a string of 300000 glyphs" do
      doc =
        page("BT /F1 12 Tf (#{String.duplicate("a", 300_000)}) Tj ET", "/Font <</F1 10 0 R>>", [
          {10, "<</Type/Font /Subtype/Type1 /BaseFont /Helvetica>>"}
        ])

      text = quickly(fn -> EmbedPdf.Text.page(doc, 0).text end)
      assert String.length(text) in 1..100_000
    end

    test "marked content that is never closed" do
      content = String.duplicate("/A BMC ", 40_000) <> String.duplicate("0 0 1 1 re f ", 20_000)
      doc = page(content)

      assert count(quickly(fn -> svg(doc) end), "<path") > 1_000
    end
  end

  test "a page within the budget is drawn whole" do
    doc =
      page(
        "/X Do 0 0 1 rg 0 0 3 3 re f",
        "/XObject <</X 10 0 R>>",
        forms(10, 4, 10, "0 0 1 1 re f")
      )

    out = quickly(fn -> svg(doc) end)
    assert count(out, ~s(fill="#000000")) == 1_000
    assert count(out, ~s(fill="#0000ff")) == 1
  end

  # ---------------------------------------------------------------- PostScript calculator (13)

  describe "type 4 functions" do
    test "a program that doubles the stack with copy" do
      program = "{ " <> String.duplicate("1000000000 copy ", 26) <> "}"

      doc =
        page(@spot_fill, @separation, [
          {10, stream("/FunctionType 4 /Domain [0 1] /Range [0 1]", program)}
        ])

      assert quickly(fn -> svg(doc) end) =~ "<path"
      # it fails as a program that cannot be run does: the inputs come back
      assert quickly(fn -> PostScript.run(PostScript.parse(program), [0.5]) end) == [0.5]
    end

    test "the stack holds a hundred operands" do
      push = fn n -> PostScript.parse("{ " <> String.duplicate("1 ", n) <> "}") end

      assert length(PostScript.run(push.(99), [0.5])) == 100
      assert PostScript.run(push.(100), [0.5]) == [0.5]
    end

    test "integers do not grow past 32 bits" do
      program = "{ pop 1 4000000 bitshift " <> String.duplicate("dup mul ", 30) <> "pop 0 }"
      assert quickly(fn -> PostScript.run(PostScript.parse(program), [0.5]) end) == [0.5]

      assert PostScript.run(PostScript.parse("{ pop 65536 dup mul }"), [0.5]) == [4_294_967_296.0]
      assert PostScript.run(PostScript.parse("{ pop 1 4 bitshift }"), [0.5]) == [16.0]
    end

    test "a program of too many tokens is not run" do
      program = "{ " <> String.duplicate("1 add ", 10_000) <> "}"
      assert quickly(fn -> PostScript.run(PostScript.parse(program), [0.5]) end) == [0.5]
      assert PostScript.run(PostScript.parse("{ 1 add 2 mul }"), [0.5]) == [3.0]
    end
  end

  # ---------------------------------------------------------------- images (14)

  describe "image sizes" do
    test "a stencil mask of 60000 × 60000 with no data" do
      doc = image_page([{10, image("/Width 60000 /Height 60000 /ImageMask true")}])
      assert quickly(fn -> svg(doc) end) =~ @placeholder
    end

    test "a gray image of 20000 × 20000 with no data" do
      doc =
        image_page([
          {10, image("/Width 20000 /Height 20000 /ColorSpace /DeviceGray /BitsPerComponent 8")}
        ])

      assert quickly(fn -> svg(doc) end) =~ @placeholder
    end

    test "a small image with a huge soft mask" do
      doc =
        image_page([
          {10,
           image(
             "/Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 11 0 R",
             <<0, 85, 170, 255>>
           )},
          {11, image("/Width 30000 /Height 30000 /ColorSpace /DeviceGray /BitsPerComponent 8")}
        ])

      assert quickly(fn -> svg(doc) end) =~ @placeholder
    end

    test "one-bit samples that would become 1.4 GB of colors" do
      doc =
        image_page([
          {10,
           image(
             "/Width 22000 /Height 22000 /ColorSpace /DeviceGray /BitsPerComponent 1 /Decode [0 0.5]"
           )}
        ])

      assert quickly(fn -> svg(doc) end) =~ @placeholder
    end

    test "a DeviceN image with a thousand colorants" do
      names = String.duplicate("/A ", 1_000)

      doc =
        image_page([
          {10,
           image(
             "/Width 3000 /Height 3000 /BitsPerComponent 8 /ColorSpace [/DeviceN [#{names}] /DeviceGray 11 0 R]"
           )},
          {11, "<</FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 1>>"}
        ])

      assert quickly(fn -> svg(doc) end) =~ @placeholder
    end

    test "the limit is configurable, and an image within it is drawn" do
      gray = "/Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8"
      doc = image_page([{10, image(gray, <<0, 85, 170, 255>>)}])

      assert svg(doc) =~ "data:image/png"
      limit(:max_image_bytes, 3)
      assert svg(doc) =~ @placeholder
    end

    test "a page's images share what it may decode" do
      limit(:max_page_image_bytes, 10)
      gray = "/Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8"

      # different images (their data differs), 4 bytes each
      images = for i <- 0..4, do: {10 + i, image(gray, <<i, 85, 170, 255>>)}
      names = for i <- 0..4, into: "", do: "/I#{i} #{10 + i} 0 R "
      content = for i <- 0..4, into: "", do: "q 10 0 0 10 #{i * 20} 0 cm /I#{i} Do Q "

      out = svg(page(content, "/XObject <<#{names}>>", images))
      assert count(out, "data:image/png") == 3
      assert count(out, @placeholder) == 2
    end
  end

  # ---------------------------------------------------------------- CCITT (15, 16)

  describe "CCITT data" do
    test "rows without end are capped" do
      params = %{"K" => -1, "Columns" => 8, "Rows" => 30_000_000_000}

      assert {:ok, rows} =
               quickly(fn -> CCITT.decode("", params, 8, 30_000_000_000, 1_000_000) end)

      assert byte_size(rows) == 1_000_000

      doc =
        image_page([
          {10,
           image(
             "/Width 8 /Height 3000000000 /ColorSpace /DeviceGray /BitsPerComponent 1 " <>
               "/Filter /CCITTFaxDecode /DecodeParms <</K -1 /Columns 8>>"
           )}
        ])

      assert quickly(fn -> svg(doc) end) =~ @placeholder
    end

    test "a wide Group 4 image with a change at every pixel" do
      columns = 100_000
      rows = 12
      # first row: white and black runs of one, in horizontal mode
      first = for _ <- 1..div(columns, 2), into: <<>>, do: <<0b001::3, 0b000111::6, 0b010::3>>
      # the others repeat it: one bit (V0) for every change
      others = :binary.copy(<<0xFF>>, div(columns * (rows - 1), 8))
      data = <<first::bitstring, others::binary>>
      data = <<data::bitstring, 0::size(rem(8 - rem(bit_size(data), 8), 8))>>

      assert {:ok, out} =
               quickly(fn ->
                 CCITT.decode(data, %{"K" => -1, "Columns" => columns}, columns, rows)
               end)

      assert out == :binary.copy(<<0b10101010>>, div(columns, 8) * rows)
    end
  end

  # ---------------------------------------------------------------- clipping (24)

  test "tens of thousands of clipping paths" do
    doc = page(String.duplicate("0 0 1 1 re W n ", 30_000) <> "0 0 1 1 re f")

    out = quickly(fn -> svg(doc) end)
    assert out =~ "<path"
    assert count(out, "<clipPath") <= 256
    assert quickly(fn -> EmbedPdf.Text.page(doc, 0).text end) == ""
  end

  # ---------------------------------------------------------------- repeated lookups (33)

  test "a font and a color space set over and over" do
    doc =
      page(
        String.duplicate("/G0 gs /CS0 cs ", 50_000) <> "BT (ok) Tj ET 7 sc 0 0 9 9 re f",
        "/ExtGState <</G0 <</Font [10 0 R 12]>>>> /ColorSpace <</CS0 [/Indexed /DeviceRGB 255 11 0 R]>>",
        [
          {10, "<</Type/Font /Subtype/Type1 /BaseFont /Helvetica>>"},
          {11, stream("", :binary.copy(<<255, 0, 0>>, 256))}
        ]
      )

    assert quickly(fn -> EmbedPdf.Text.page(doc, 0).text end) == "ok"
    assert quickly(fn -> svg(doc) end) =~ "#ff0000"
  end

  test "a dash pattern of thousands of elements" do
    dashes = String.duplicate("1 ", 5_000)
    doc = page("[#{dashes}] 0 d " <> String.duplicate("0 0 m 9 9 l S ", 500))

    assert byte_size(quickly(fn -> svg(doc) end)) < 500_000
  end
end
