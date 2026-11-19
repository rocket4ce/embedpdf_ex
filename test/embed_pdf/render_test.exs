defmodule EmbedPdf.RenderTest do
  use ExUnit.Case, async: true
  import EmbedPdf.TestHelpers

  alias EmbedPdf.PDF.{Document, Serializer, Stream}
  alias EmbedPdf.Render.{CCITT, PNG, SVG}

  setup_all do
    Mix.ensure_application!(:xmerl)
    :ok
  end

  # ---------------------------------------------------------------- helpers

  defp svg(doc, index \\ 0, opts \\ []),
    do: doc |> SVG.render_page(index, opts) |> IO.iodata_to_binary()

  defp well_formed!(svg) do
    {doc, _} = apply(:xmerl_scan, :string, [:binary.bin_to_list(svg), [quiet: true]])
    doc
  end

  defp size_attrs(svg) do
    [_, w, h] = Regex.run(~r/<svg[^>]* width="([\d.]+)" height="([\d.]+)"/, svg)

    {String.to_float(w <> if(String.contains?(w, "."), do: "", else: ".0")),
     String.to_float(h <> if(String.contains?(h, "."), do: "", else: ".0"))}
  end

  # A one-page PDF built from a content stream and resources.
  defp build(content, resources, opts \\ []) do
    extra = Keyword.get(opts, :objects, %{})
    page_extra = Keyword.get(opts, :page, %{})

    objects =
      %{
        1 => %{"Type" => "Catalog", "Pages" => {:ref, 2, 0}},
        2 => %{"Type" => "Pages", "Kids" => [{:ref, 3, 0}], "Count" => 1},
        3 =>
          Map.merge(
            %{
              "Type" => "Page",
              "Parent" => {:ref, 2, 0},
              "MediaBox" => [0, 0, 200, 100],
              "Resources" => resources,
              "Contents" => {:ref, 4, 0}
            },
            page_extra
          ),
        4 => %Stream{dict: %{}, raw: content}
      }
      |> Map.merge(extra)

    # streams must be indirect objects: hoist the ones written inline
    {objects, _} =
      Enum.reduce(Map.keys(objects), {objects, 1000}, fn num, {objs, next} ->
        {value, {extra, next}} = hoist(objs[num], {%{}, next}, true)
        {objs |> Map.put(num, value) |> Map.merge(extra), next}
      end)

    doc = %Document{objects: objects, trailer: %{"Root" => {:ref, 1, 0}}, next_num: 2000}
    {:ok, doc} = EmbedPdf.open(Serializer.save(doc, compress: false))
    doc
  end

  defp hoist(%Stream{dict: dict} = s, acc, top?) do
    {dict, {extra, next}} = hoist(dict, acc, false)
    s = %{s | dict: dict}
    if top?, do: {s, {extra, next}}, else: {{:ref, next, 0}, {Map.put(extra, next, s), next + 1}}
  end

  defp hoist(map, acc, _top?) when is_map(map) do
    Enum.reduce(map, {%{}, acc}, fn {k, v}, {m, acc} ->
      {v, acc} = hoist(v, acc, false)
      {Map.put(m, k, v), acc}
    end)
  end

  defp hoist(list, acc, _top?) when is_list(list) do
    {items, acc} = Enum.map_reduce(list, acc, &hoist(&1, &2, false))
    {items, acc}
  end

  defp hoist(v, acc, _top?), do: {v, acc}

  defp image(dict, data),
    do: %Stream{dict: Map.merge(%{"Type" => "XObject", "Subtype" => "Image"}, dict), raw: data}

  defp decode_png!(png) do
    <<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>> = png
    chunks = read_chunks(rest, [])
    {"IHDR", <<w::32, h::32, depth, color, _::binary>>} = List.keyfind(chunks, "IHDR", 0)

    idat =
      chunks
      |> Enum.filter(&(elem(&1, 0) == "IDAT"))
      |> Enum.map(&elem(&1, 1))
      |> IO.iodata_to_binary()

    %{
      width: w,
      height: h,
      depth: depth,
      color: color,
      raw: :zlib.uncompress(idat),
      chunks: Enum.map(chunks, &elem(&1, 0))
    }
  end

  defp read_chunks(<<>>, acc), do: Enum.reverse(acc)

  defp read_chunks(
         <<len::32, type::binary-4, data::binary-size(len), crc::32, rest::binary>>,
         acc
       ) do
    assert :erlang.crc32([type, data]) == crc
    read_chunks(rest, [{type, data} | acc])
  end

  defp data_uris(svg, mime),
    do:
      Regex.scan(~r/data:#{mime};base64,([A-Za-z0-9+\/=]+)/, svg)
      |> Enum.map(fn [_, b] -> Base.decode64!(b) end)

  # ---------------------------------------------------------------- fixtures

  describe "fixture pages" do
    test "every page of every fixture renders to well-formed SVG of the page size" do
      for file <- Path.wildcard(fixture("*.pdf")) do
        opts = if String.contains?(file, "protected"), do: [password: "embedpdf"], else: []
        {:ok, doc} = EmbedPdf.open(File.read!(file), opts)

        for i <- 0..(EmbedPdf.page_count(doc) - 1) do
          out = svg(doc, i)
          well_formed!(out)
          {w, h} = EmbedPdf.page_size(doc, i)
          {sw, sh} = size_attrs(out)
          assert_in_delta sw, w, 0.01, "#{Path.basename(file)} page #{i + 1}"
          assert_in_delta sh, h, 0.01
        end
      end
    end

    test "images become data URIs with their soft masks" do
      out = svg(open!("welcome.pdf"))
      pngs = data_uris(out, "image/png")
      assert pngs != []
      assert Enum.all?(pngs, &match?(%{width: _}, decode_png!(&1)))
      assert out =~ ~s(style="mask-type:alpha")
    end

    test "axial shadings become linear gradients" do
      out = svg(open!("demo_protected.pdf", password: "embedpdf"), 10)
      assert out =~ "<linearGradient"
      assert out =~ "<stop offset="
    end

    test "tiling patterns become SVG patterns" do
      out = svg(open!("demo_protected.pdf", password: "embedpdf"), 12)
      assert out =~ "<pattern "
      assert out =~ ~r/fill="url\(#p12t\d+\)"/
    end

    test "clip paths and transparency groups" do
      out = svg(open!("ebook.pdf"), 0)
      assert out =~ "<clipPath"
      assert out =~ ~r/<g[^>]* mask="url\(#p0m\d+\)"/
    end

    test "rotation swaps the page size" do
      doc = open!("welcome.pdf")
      {w, h} = EmbedPdf.page_size(doc, 0)

      for rot <- [90, 270] do
        assert {^h, ^w} = size_attrs(svg(doc, 0, rotation: rot))
      end

      assert {^w, ^h} = size_attrs(svg(doc, 0, rotation: 180))
      refute svg(doc, 0, rotation: 180) == svg(doc, 0)
    end

    test "viewbox renders a region" do
      out = svg(open!("welcome.pdf"), 0, viewbox: {100, 50, 300, 150})
      assert out =~ ~s(viewBox="100 50 200 100" width="200" height="100")
    end

    test "background can be turned off" do
      doc = open!("sketch.pdf")
      assert svg(doc) =~ ~s(fill="#fff")
      refute svg(doc, 0, background: nil) =~ ~s(<rect width="612" height="792" fill="#fff"/>)
    end

    test "ids are prefixed per page" do
      doc = open!("welcome.pdf")
      ids = Regex.scan(~r/ id="([^"]+)"/, svg(doc, 1)) |> Enum.map(&List.last/1)
      assert ids != []
      assert Enum.all?(ids, &String.starts_with?(&1, "p1"))
      assert ids == Enum.uniq(ids)
    end
  end

  describe "annotations" do
    test "appearance streams are drawn and can be skipped" do
      doc = open!("ebook-annotated.pdf")
      with_annots = svg(doc)
      without = svg(doc, 0, annotations: false)
      assert byte_size(with_annots) > byte_size(without)

      page = Document.page(doc, 0)
      nums = for {{:ref, n, _}, _} <- SVG.annotations(doc, page), do: n
      skipped = svg(doc, 0, skip_annotations: nums)
      assert byte_size(skipped) < byte_size(with_annots)
    end

    test "render_annotation returns a fragment for one annotation" do
      doc = open!("ebook-annotated.pdf")
      page = Document.page(doc, 0)
      [{ref, _} | _] = SVG.annotations(doc, page)
      fragment = doc |> SVG.render_annotation(0, ref) |> IO.iodata_to_binary()
      assert String.starts_with?(fragment, "<g>")
      well_formed!(fragment)
      assert SVG.render_annotation(doc, 0, {:ref, 999_999, 0}) == nil
    end

    test "annotations without appearance streams are synthesized" do
      annots = [
        %{
          "Subtype" => "Highlight",
          "Rect" => [10, 10, 60, 20],
          "QuadPoints" => [10, 20, 60, 20, 10, 10, 60, 10],
          "C" => [1, 1, 0]
        },
        %{
          "Subtype" => "Square",
          "Rect" => [70, 10, 100, 40],
          "C" => [1, 0, 0],
          "IC" => [0, 0, 1]
        },
        %{"Subtype" => "Circle", "Rect" => [110, 10, 140, 40], "C" => [0, 1, 0]},
        %{
          "Subtype" => "Ink",
          "Rect" => [0, 0, 200, 100],
          "InkList" => [[10, 50, 20, 60, 30, 50]],
          "C" => [0, 0, 1]
        },
        %{
          "Subtype" => "Line",
          "Rect" => [0, 0, 200, 100],
          "L" => [10, 90, 100, 90],
          "LE" => ["None", "ClosedArrow"],
          "C" => [0, 0, 0]
        },
        %{
          "Subtype" => "FreeText",
          "Rect" => [100, 50, 190, 90],
          "Contents" => {:string, "Hello <world>"},
          "DA" => {:string, "/Helv 10 Tf 1 0 0 rg"}
        },
        %{"Subtype" => "Text", "Rect" => [150, 70, 170, 90], "Contents" => {:string, "note"}},
        %{"Subtype" => "Square", "Rect" => [0, 0, 10, 10], "F" => 2}
      ]

      objects =
        annots
        |> Enum.with_index(10)
        |> Map.new(fn {a, i} -> {i, Map.put(a, "Type", "Annot")} end)

      refs = for i <- 10..(9 + length(annots)), do: {:ref, i, 0}
      doc = build("", %{}, objects: objects, page: %{"Annots" => refs})
      out = svg(doc)
      well_formed!(out)
      assert out =~ "mix-blend-mode:multiply"
      assert out =~ "<ellipse"
      assert out =~ "Hello &lt;world&gt;"
      assert out =~ ~s(fill="#0000ff")
      # the hidden square (F=2) is not drawn
      refute out =~ ~s(<rect x="0.5" y="0.5")
    end
  end

  describe "synthetic content" do
    test "paths with fill rules, strokes, dashes, caps and joins" do
      doc =
        build(
          "1 0 0 rg 0 0 1 RG 3 w 1 J 2 j [4 2] 1 d 10 10 50 50 re B* 0.5 g 0 w 100 10 m 150 60 l S",
          %{}
        )

      out = svg(doc)
      well_formed!(out)
      assert out =~ ~s(fill="#ff0000" fill-rule="evenodd")
      assert out =~ ~s(stroke-dasharray="4 2" stroke-dashoffset="1")
      assert out =~ ~s(stroke-linecap="round")
      assert out =~ ~s(stroke-linejoin="bevel")
      assert out =~ ~s(vector-effect="non-scaling-stroke")
    end

    test "clipping paths open groups" do
      out =
        svg(build("q 0 0 100 50 re W n 1 0 0 rg 0 0 200 100 re f Q 0 1 0 rg 0 0 10 10 re f", %{}))

      assert out =~ ~r/<clipPath id="p0c\d+"><path d="M0 0h100v50h-100Z"/
      assert out =~ ~r/<g clip-path="url\(#p0c\d+\)"><path[^>]*fill="#ff0000"/
    end

    test "fill and stroke opacity, blend modes" do
      res = %{"ExtGState" => %{"G1" => %{"ca" => 0.5, "CA" => 0.25, "BM" => "Multiply"}}}
      out = svg(build("/G1 gs 1 0 0 rg 0 0 1 RG 0 0 50 50 re B", res))
      assert out =~ ~s(fill-opacity="0.5")
      assert out =~ ~s(stroke-opacity="0.25")
      assert out =~ "mix-blend-mode:multiply"
    end

    test "color spaces" do
      res = %{
        "ColorSpace" => %{
          "Sep" => [
            "Separation",
            "Spot",
            "DeviceCMYK",
            %{
              "FunctionType" => 2,
              "Domain" => [0, 1],
              "C0" => [0, 0, 0, 0],
              "C1" => [0, 1, 1, 0],
              "N" => 1
            }
          ],
          "Idx" => ["Indexed", "DeviceRGB", 1, {:string, <<255, 0, 0, 0, 255, 0>>}],
          "Lab" => ["Lab", %{"WhitePoint" => [0.9505, 1, 1.089]}]
        }
      }

      out =
        svg(
          build(
            "0 0 0 1 k 0 0 10 10 re f /Sep cs 1 sc 10 0 10 10 re f /Idx cs 1 sc 20 0 10 10 re f /Lab cs 100 0 0 sc 30 0 10 10 re f",
            res
          )
        )

      assert out =~ ~s(fill="#000000")
      assert out =~ ~s(fill="#ff0000")
      assert out =~ ~s(fill="#00ff00")
      assert out =~ ~s(fill="#ffffff")
    end

    test "axial and radial shadings, with and without extend" do
      axial = %{
        "ShadingType" => 2,
        "ColorSpace" => "DeviceRGB",
        "Coords" => [0, 0, 100, 0],
        "Function" => %{
          "FunctionType" => 2,
          "Domain" => [0, 1],
          "C0" => [1, 0, 0],
          "C1" => [0, 0, 1],
          "N" => 1
        },
        "Extend" => [true, false]
      }

      radial = %{
        "ShadingType" => 3,
        "ColorSpace" => "DeviceGray",
        "Coords" => [50, 50, 40, 50, 50, 0],
        "Function" => %{
          "FunctionType" => 2,
          "Domain" => [0, 1],
          "C0" => [0],
          "C1" => [1],
          "N" => 1
        }
      }

      res = %{
        "Shading" => %{"A" => axial},
        "Pattern" => %{"P" => %{"PatternType" => 2, "Shading" => radial}}
      }

      out = svg(build("/A sh /Pattern cs /P scn 0 0 100 100 re f", res))
      well_formed!(out)
      assert out =~ "<linearGradient"
      assert out =~ "<radialGradient"
      # extend false at the end: a transparent stop
      assert out =~ ~s(stop-opacity="0")
      # r0 > r1 swaps the circles
      assert out =~ ~s(fr="0")
    end

    test "function-based and mesh shadings" do
      fbased = %{
        "ShadingType" => 1,
        "ColorSpace" => "DeviceRGB",
        "Domain" => [0, 1, 0, 1],
        "Matrix" => [100, 0, 0, 100, 0, 0],
        "Function" => %Stream{
          dict: %{"FunctionType" => 4, "Domain" => [0, 1, 0, 1], "Range" => [0, 1, 0, 1, 0, 1]},
          raw: "{ 0 }"
        }
      }

      # one free-form triangle: flag, x, y (8 bits), r g b
      mesh_data = <<0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 0, 0, 255>>

      mesh = %Stream{
        dict: %{
          "ShadingType" => 4,
          "ColorSpace" => "DeviceRGB",
          "BitsPerCoordinate" => 8,
          "BitsPerComponent" => 8,
          "BitsPerFlag" => 8,
          "Decode" => [0, 100, 0, 100, 0, 1, 0, 1, 0, 1]
        },
        raw: mesh_data
      }

      out = svg(build("/F sh /M sh", %{"Shading" => %{"F" => fbased, "M" => mesh}}, objects: %{}))
      well_formed!(out)
      assert out =~ "data:image/png"
      assert out =~ ~r/<path d="M[\d.]+ [\d.]+L[\d.]+ [\d.]+L[\d.]+ [\d.]+Z" fill="#/
    end

    test "uncolored tiling patterns take the tint" do
      tile = %Stream{
        dict: %{
          "PatternType" => 1,
          "PaintType" => 2,
          "TilingType" => 1,
          "BBox" => [0, 0, 10, 10],
          "XStep" => 10,
          "YStep" => 10,
          "Resources" => %{}
        },
        raw: "0 0 5 5 re f"
      }

      res = %{"Pattern" => %{"T" => tile}, "ColorSpace" => %{"PCS" => ["Pattern", "DeviceRGB"]}}
      out = svg(build("/PCS cs 0 0 1 /T scn 0 0 100 100 re f", res))
      assert out =~ ~r/<pattern id="p0t\d+" patternUnits="userSpaceOnUse"/
      assert out =~ ~s(fill="#0000ff")
    end

    test "inline images, stencil masks and colorful images" do
      gray16 =
        image(
          %{"Width" => 2, "Height" => 1, "BitsPerComponent" => 16, "ColorSpace" => "DeviceGray"},
          <<0, 0, 255, 255>>
        )

      cmyk =
        image(
          %{"Width" => 1, "Height" => 1, "BitsPerComponent" => 8, "ColorSpace" => "DeviceCMYK"},
          <<0, 255, 255, 0>>
        )

      indexed =
        image(
          %{
            "Width" => 2,
            "Height" => 1,
            "BitsPerComponent" => 1,
            "ColorSpace" => ["Indexed", "DeviceRGB", 1, {:string, <<0, 0, 0, 0, 255, 0>>}],
            "Mask" => [0, 0]
          },
          <<0b01000000>>
        )

      inverted =
        image(
          %{
            "Width" => 8,
            "Height" => 1,
            "BitsPerComponent" => 1,
            "ColorSpace" => "DeviceGray",
            "Decode" => [1, 0]
          },
          <<0b10101010>>
        )

      stencil = image(%{"Width" => 8, "Height" => 1, "ImageMask" => true}, <<0b11110000>>)

      smask =
        image(
          %{"Width" => 1, "Height" => 1, "BitsPerComponent" => 8, "ColorSpace" => "DeviceGray"},
          <<128>>
        )

      with_smask =
        image(
          %{
            "Width" => 1,
            "Height" => 1,
            "BitsPerComponent" => 8,
            "ColorSpace" => "DeviceRGB",
            "SMask" => {:ref, 50, 0}
          },
          <<255, 0, 0>>
        )

      jpeg =
        image(
          %{
            "Width" => 8,
            "Height" => 6,
            "BitsPerComponent" => 8,
            "ColorSpace" => "DeviceRGB",
            "Filter" => "DCTDecode"
          },
          File.read!(fixture("render/tiny.jpg"))
        )

      jpx = image(%{"Width" => 8, "Height" => 6, "Filter" => "JPXDecode"}, "not decoded")

      xobjects = %{
        "G" => gray16,
        "C" => cmyk,
        "I" => indexed,
        "V" => inverted,
        "S" => stencil,
        "M" => with_smask,
        "J" => jpeg,
        "X" => jpx
      }

      content =
        "q 20 0 0 20 0 0 cm /G Do Q q 20 0 0 20 20 0 cm /C Do Q q 20 0 0 20 40 0 cm /I Do Q " <>
          "q 20 0 0 20 60 0 cm /V Do Q 0 0 1 rg q 20 0 0 20 80 0 cm /S Do Q q 20 0 0 20 100 0 cm /M Do Q " <>
          "q 20 0 0 20 120 0 cm /J Do Q q 20 0 0 20 140 0 cm /X Do Q " <>
          "q 20 0 0 20 160 0 cm BI /W 2 /H 1 /BPC 8 /CS /RGB ID \xFF\x00\x00\x00\xFF\x00 EI Q"

      out = svg(build(content, %{"XObject" => xobjects}, objects: %{50 => smask}))
      well_formed!(out)

      pngs = out |> data_uris("image/png") |> Enum.map(&decode_png!/1)
      # gray16, cmyk, indexed, inverted, stencil, smask image + its mask, inline image
      assert length(pngs) >= 8
      assert Enum.any?(pngs, &(&1.depth == 16 and &1.color == 0))
      # palette images carry PLTE and tRNS (indexed color key, stencil)
      assert Enum.count(pngs, &("tRNS" in &1.chunks)) >= 3
      # the stencil is painted with the fill color
      assert Enum.any?(pngs, fn png -> png.color == 3 and png.width == 8 end)
      # CMYK (0,1,1,0) is red
      assert Enum.any?(pngs, &(&1.raw == <<0, 255, 0, 0>>))
      # inverted 1-bit gray
      assert Enum.any?(pngs, &(&1.raw == <<0, 0b01010101>>))
      assert [_] = data_uris(out, "image/jpeg")
      assert out =~ ~s(fill="#e6e6e6")
      assert out =~ ~s(<mask id=)
    end

    test "soft masks from the graphics state" do
      group = %Stream{
        dict: %{
          "Type" => "XObject",
          "Subtype" => "Form",
          "BBox" => [0, 0, 200, 100],
          "Group" => %{"S" => "Transparency", "CS" => "DeviceGray"}
        },
        raw: "1 g 0 0 100 100 re f"
      }

      res = %{
        "ExtGState" => %{"SM" => %{"SMask" => %{"S" => "Luminosity", "G" => {:ref, 60, 0}}}}
      }

      out = svg(build("/SM gs 1 0 0 rg 0 0 200 100 re f", res, objects: %{60 => group}))
      well_formed!(out)
      assert out =~ ~s(style="mask-type:luminance")
      assert out =~ ~r/<g mask="url\(#p0m\d+\)"><path[^>]*fill="#ff0000"/
    end

    test "text without font programs falls back to positioned SVG text" do
      font = %{
        "Type" => "Font",
        "Subtype" => "Type1",
        "BaseFont" => "Helvetica-Bold",
        "Encoding" => "WinAnsiEncoding"
      }

      out = svg(build("BT /F1 12 Tf 10 50 Td (Hi & <you>) Tj ET", %{"Font" => %{"F1" => font}}))
      well_formed!(out)
      assert out =~ "<text "
      assert out =~ ~s(font-weight="bold")
      assert out =~ "Hi&amp;&lt;you&gt;"
    end

    test "Type 3 glyphs are drawn from their procedures" do
      proc = %Stream{dict: %{}, raw: "1000 0 0 0 750 750 d1 0 0 750 750 re f"}

      font = %{
        "Type" => "Font",
        "Subtype" => "Type3",
        "FontBBox" => [0, 0, 750, 750],
        "FontMatrix" => [0.001, 0, 0, 0.001, 0, 0],
        "CharProcs" => %{"square" => proc},
        "Encoding" => %{"Type" => "Encoding", "Differences" => [65, "square"]},
        "FirstChar" => 65,
        "LastChar" => 65,
        "Widths" => [1000]
      }

      out = svg(build("1 0 0 rg BT /T3 20 Tf 10 10 Td (AAA) Tj ET", %{"Font" => %{"T3" => font}}))
      assert length(Regex.scan(~r/<path d="M0 0h750v750h-750Z"/, out)) == 3
      assert out =~ ~s(fill="#ff0000")
      refute out =~ "<text"
    end

    test "invisible text (render mode 3) is not drawn" do
      font = %{"Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Helvetica"}
      out = svg(build("BT 3 Tr /F1 12 Tf 10 50 Td (secret) Tj ET", %{"Font" => %{"F1" => font}}))
      refute out =~ "secret"
    end

    test "page rotation and the extra view rotation compose" do
      doc = build("1 0 0 rg 0 0 10 10 re f", %{}, page: %{"Rotate" => 90})
      assert {100.0, 200.0} == size_attrs(svg(doc))
      assert {200.0, 100.0} == size_attrs(svg(doc, 0, rotation: 90))
    end

    test "CCITT fax images decode (G4, G3 1D and 2D)" do
      for name <- ~w(ccitt_g4.pdf ccitt_g3_1d.pdf ccitt_g3_2d.pdf) do
        out = svg(open!("render/" <> name))
        assert [png] = data_uris(out, "image/png")
        decoded = decode_png!(png)
        assert {decoded.width, decoded.height} == {300, 120}
        # the black rectangle in the top-left corner is decoded: some black pixels
        assert decoded.raw =~ <<0>> or String.contains?(decoded.raw, <<0xFF>>)
        refute out =~ "e6e6e6"
      end
    end
  end

  describe "PNG encoder" do
    test "writes a valid signature, chunks and CRCs" do
      png = PNG.encode(2, 2, :rgb, 8, <<255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255>>)
      decoded = decode_png!(png)
      assert decoded.chunks == ["IHDR", "IDAT", "IEND"]
      assert {decoded.width, decoded.height, decoded.depth, decoded.color} == {2, 2, 8, 2}
      assert decoded.raw == <<0, 255, 0, 0, 0, 255, 0, 0, 0, 0, 255, 255, 255, 255>>
    end

    test "palette images with transparency" do
      png =
        PNG.encode(4, 1, :palette, 2, <<0b00011011>>,
          palette: [{0, 0, 0}, {255, 0, 0}, {0, 255, 0}, {0, 0, 255}],
          transparency: [0, 255, 255, 255]
        )

      assert decode_png!(png).chunks == ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"]
    end

    test "short data is padded" do
      png = PNG.encode(3, 3, :gray, 8, <<1, 2>>)
      assert byte_size(decode_png!(png).raw) == 3 * 4
    end
  end

  describe "CCITT" do
    test "an all-white G4 line" do
      # one row of 8 white pixels: horizontal mode, white 8 (10011), black 0 (0000110111)
      bits = <<0b001::3, 0b10011::5, 0b0000110111::10, 0::6>>
      assert {:ok, <<0xFF>>} = CCITT.decode(bits, %{"K" => -1, "Columns" => 8}, 8, 1)

      assert {:ok, <<0x00>>} =
               CCITT.decode(bits, %{"K" => -1, "Columns" => 8, "BlackIs1" => true}, 8, 1)
    end

    test "garbage yields white rows instead of crashing" do
      assert {:ok, data} =
               CCITT.decode(<<0, 0, 0>>, %{"K" => -1, "Columns" => 16, "Rows" => 2}, 16, 2)

      assert byte_size(data) == 4
    end
  end

  test "SVG escaping drops characters XML forbids" do
    assert SVG.escape("a<b>&\"c\u0001") == "a&lt;b&gt;&amp;&quot;c"
  end

  test "pages render within the time budget" do
    doc = open!("welcome.pdf")
    {micros, _} = :timer.tc(fn -> svg(doc, 0) end)
    assert micros < 2_000_000
  end
end
