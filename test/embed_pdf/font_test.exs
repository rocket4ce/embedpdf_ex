defmodule EmbedPdf.FontTest do
  use ExUnit.Case, async: true
  import EmbedPdf.TestHelpers
  import Bitwise

  alias EmbedPdf.Font
  alias EmbedPdf.Font.{CFF, Outline, Program, TrueType, Type1}
  alias EmbedPdf.Render.Interpreter

  # ---------------------------------------------------------------- fixtures

  defp glyphs_used(doc) do
    Enum.flat_map(doc.pages, fn page ->
      Interpreter.run_page(
        doc,
        page,
        fn
          {:glyph, g}, acc -> [g | acc]
          _, acc -> acc
        end,
        [],
        text_only: true
      )
    end)
  end

  defp kind(font) do
    cond do
      font.program -> font.program.kind
      font.type == "Type3" -> :type3
      true -> :none
    end
  end

  test "embedded programs in every fixture produce plausible outlines" do
    files = Path.wildcard(fixture("*.pdf"))

    totals =
      Enum.reduce(files, %{}, fn file, acc ->
        opts = if String.contains?(file, "protected"), do: [password: "embedpdf"], else: []
        {:ok, doc} = EmbedPdf.open(File.read!(file), opts)

        doc
        |> glyphs_used()
        |> Enum.reduce(acc, fn %{font: font, glyph: glyph}, acc ->
          case kind(font) do
            k when k in [:none, :type3] ->
              acc

            k ->
              outline = Font.glyph_outline(font, glyph)

              plausible? =
                case outline && Outline.bbox(outline) do
                  nil -> outline == []
                  {x0, y0, x1, y1} -> x0 >= -1 and y0 >= -1 and x1 <= 2 and y1 <= 2
                end

              Map.update(acc, k, {1, if(plausible?, do: 1, else: 0)}, fn {n, ok} ->
                {n + 1, ok + if(plausible?, do: 1, else: 0)}
              end)
          end
        end)
      end)

    # the fixtures carry TrueType (simple and CID) and Type 1 programs
    assert Map.has_key?(totals, :truetype)
    assert Map.has_key?(totals, :type1)

    for {k, {n, ok}} <- totals do
      assert ok / n >= 0.98, "#{k}: only #{ok} of #{n} glyphs have plausible outlines"
    end
  end

  test "a Type1C (bare CFF) font draws every printable code" do
    doc = open!("kept_fonts_form.pdf")

    font =
      doc.objects
      |> Enum.filter(fn {_, v} -> match?(%{"Type" => "Font"}, v) end)
      |> Enum.map(fn {n, _} -> Font.load(doc, {:ref, n, 0}) end)
      |> Enum.find(&(&1.program && &1.program.kind == :cff))

    assert font

    outlines = for code <- 33..126, do: Font.glyph_outline(font, {code, code, "", 0.6, 1})
    assert Enum.all?(outlines, &(is_list(&1) and &1 != []))

    # "E" of a fixed-pitch font: an upright glyph within one em
    {x0, y0, x1, y1} = Outline.bbox(Font.glyph_outline(font, {?E, ?E, "E", 0.6, 1}))
    assert x0 >= 0 and x1 <= 0.7 and y0 >= -0.01 and y1 > 0.4 and y1 < 0.8
  end

  test "the Type 1 fonts of the protected fixture parse with their encodings" do
    {:ok, doc} = EmbedPdf.open(File.read!(fixture("demo_protected.pdf")), password: "embedpdf")

    t1 =
      doc.objects
      |> Enum.filter(fn {_, v} -> match?(%{"Type" => "Font", "Subtype" => "Type1"}, v) end)
      |> Enum.map(fn {n, _} -> Font.load(doc, {:ref, n, 0}) end)
      |> Enum.filter(&(&1.program && &1.program.kind == :type1))

    assert length(t1) > 5
    assert Enum.all?(t1, &(map_size(&1.program.t1.charstrings) > 0))
  end

  test "text extraction still works through the program lookups" do
    assert EmbedPdf.text(open!("welcome.pdf"), 1) =~ "PDF was born"
  end

  # ---------------------------------------------------------------- TrueType

  # a minimal sfnt: glyph 1 is a triangle with one off-curve point,
  # glyph 2 a composite of glyph 1 shifted by (100, 0) and scaled by 0.5
  defp build_truetype do
    simple =
      <<1::signed-16, 0::signed-16, 0::signed-16, 1000::signed-16, 1000::signed-16>> <>
        <<2::16, 0::16>> <>
        <<1, 0, 1>> <>
        <<0::signed-16, 1000::signed-16, -500::signed-16>> <>
        <<0::signed-16, 1000::signed-16, -1000::signed-16>>

    simple = pad4(simple)

    composite =
      <<-1::signed-16, 0::64>> <>
        <<0x0001 ||| 0x0002 ||| 0x0008::16, 1::16, 100::signed-16, 0::signed-16, 8192::signed-16>>

    composite = pad4(composite)
    glyf = simple <> composite
    loca = <<0::32, 0::32, byte_size(simple)::32, byte_size(glyf)::32>>

    head =
      <<0x00010000::32, 0::32, 0::32, 0x5F0F3CF5::32, 0::16, 1000::16>> <>
        <<0::size(30 * 8)>> <> <<1::signed-16, 0::16>>

    maxp = <<0x00010000::32, 3::16>> <> <<0::size(26 * 8)>>

    # cmap format 4: 'A' (0x41) -> 1, 'B' -> 2, plus the 0xFFFF terminator
    seg = 2

    fmt4 =
      <<4::16, 0::16, 0::16, seg * 2::16, 2::16, 0::16, 0::16>> <>
        <<0x42::16, 0xFFFF::16>> <>
        <<0::16>> <>
        <<0x41::16, 0xFFFF::16>> <>
        <<1 - 0x41 &&& 0xFFFF::16, 1::16>> <>
        <<0::16, 0::16>>

    fmt4 =
      binary_part(fmt4, 0, 2) <>
        <<byte_size(fmt4)::16>> <> binary_part(fmt4, 4, byte_size(fmt4) - 4)

    cmap = <<0::16, 1::16, 3::16, 1::16, 12::32>> <> fmt4

    tables = [{"cmap", cmap}, {"glyf", glyf}, {"head", head}, {"loca", loca}, {"maxp", maxp}]
    sfnt(tables)
  end

  defp pad4(bin), do: bin <> :binary.copy(<<0>>, rem(4 - rem(byte_size(bin), 4), 4))

  defp sfnt(tables) do
    n = length(tables)
    dir_size = 12 + 16 * n

    {records, data, _} =
      Enum.reduce(tables, {[], [], dir_size}, fn {tag, body}, {recs, data, off} ->
        body = pad4(body)

        {[<<tag::binary-4, 0::32, off::32, byte_size(body)::32>> | recs], [body | data],
         off + byte_size(body)}
      end)

    IO.iodata_to_binary([
      <<0x00010000::32, n::16, 0::48>>,
      Enum.reverse(records),
      Enum.reverse(data)
    ])
  end

  test "TrueType: simple and composite glyphs, quadratic to cubic, cmap format 4" do
    {:ok, tt} = TrueType.parse(build_truetype())
    assert tt.units_per_em == 1000
    assert tt.num_glyphs == 3
    assert TrueType.unicode_lookup(tt, ?A) == 1
    assert TrueType.unicode_lookup(tt, ?B) == 2

    [{:move, 0, 0}, {:curve, cx1, cy1, cx2, cy2, x, y}, :close] =
      tt |> TrueType.glyph(1) |> norm()

    # quad from (0,0) via (1,1) to (0.5, 0): control points at 2/3 toward (1,1)
    assert_in_delta cx1, 2 / 3, 1.0e-9
    assert_in_delta cy1, 2 / 3, 1.0e-9
    assert_in_delta cx2, 0.5 + (1 - 0.5) * 2 / 3, 1.0e-9
    assert_in_delta cy2, 2 / 3, 1.0e-9
    assert {x, y} == {0.5, 0}

    # composite: shifted by 100 units, scaled by 0.5
    {x0, _y0, x1, y1} = tt |> TrueType.glyph(2) |> Outline.bbox()
    assert_in_delta x0, 0.1, 1.0e-9
    # control points count: the curve's second control point is at x = 0.8333
    assert_in_delta x1, 0.1 + 0.5 * (0.5 + 0.5 * 2 / 3), 1.0e-9
    assert_in_delta y1, 0.5 * 2 / 3, 1.0e-9

    assert TrueType.glyph(tt, 0) == []
    assert TrueType.glyph(tt, 99) == nil
    assert Map.get(tt.reverse_unicode, 1) == ?A
  end

  test "TrueType: the program layer maps names through the Unicode cmap" do
    program = Program.parse(build_truetype())
    assert program.kind == :truetype

    font = %Font{type: "TrueType", encoding: %{65 => "A", 66 => "B"}, program: program}
    assert [{:move, _, _} | _] = Font.glyph_outline(font, {65, 65, "A", 0.5, 1})
    assert Program.unicode_for_gid(program, 2) == "B"
  end

  # ---------------------------------------------------------------- CFF / Type 2

  defp num(v) when v >= -107 and v <= 107, do: <<v + 139>>

  defp num(v) when v >= 108 and v <= 1131 do
    v = v - 108
    <<div(v, 256) + 247, rem(v, 256)>>
  end

  defp num(v) when v <= -108 and v >= -1131 do
    v = -v - 108
    <<div(v, 256) + 251, rem(v, 256)>>
  end

  defp num(v), do: <<28, v::signed-16>>

  defp cs(items),
    do:
      IO.iodata_to_binary(
        Enum.map(items, fn
          i when is_integer(i) -> num(i)
          {:op, o} -> <<o>>
          {:esc, o} -> <<12, o>>
        end)
      )

  defp index([]), do: <<0::16>>

  defp index(items) do
    {offsets, _} = Enum.map_reduce(items, 1, fn item, off -> {off, off + byte_size(item)} end)
    last = 1 + Enum.reduce(items, 0, &(byte_size(&1) + &2))

    <<length(items)::16, 4,
      Enum.map(offsets ++ [last], &<<&1::32>>) |> IO.iodata_to_binary()::binary,
      IO.iodata_to_binary(items)::binary>>
  end

  defp run_type2(items, subrs \\ []) do
    ctx = %{gsubrs: index_tuple([]), subrs: index_tuple(subrs), seac: fn _ -> nil end}
    {:ok, cmds} = CFF.Type2.run(cs(items), ctx)
    norm(cmds)
  end

  # whole floats as integers, so expectations read naturally
  defp norm(cmds) do
    Enum.map(cmds, fn
      :close ->
        :close

      t ->
        t
        |> Tuple.to_list()
        |> Enum.map(fn
          v when is_float(v) and v == trunc(v) -> trunc(v)
          v -> v
        end)
        |> List.to_tuple()
    end)
  end

  defp index_tuple(items), do: items |> index() |> CFF.read_index() |> elem(0)

  test "Type 2: width operand, moves, lines and implicit close" do
    cmds = run_type2([500, 100, 200, {:op, 21}, 50, 0, 0, 50, {:op, 5}, 30, {:op, 6}, {:op, 14}])

    assert cmds == [
             {:move, 100, 200},
             {:line, 150, 200},
             {:line, 150, 250},
             {:line, 180, 250},
             :close
           ]
  end

  test "Type 2: hintmask bytes are skipped using the stem count" do
    # 2 hstems + 1 implicit vstem = 3 stems -> 1 mask byte; 0xFF would otherwise read as a number
    bin =
      cs([0, 10, 20, 10, {:op, 18}, 5, 10, {:op, 19}]) <>
        <<0xFF>> <> cs([10, 10, {:op, 21}, {:op, 14}])

    ctx = %{gsubrs: index_tuple([]), subrs: index_tuple([]), seac: fn _ -> nil end}
    assert {:ok, cmds} = CFF.Type2.run(bin, ctx)
    assert norm(cmds) == [{:move, 10, 10}, :close]
  end

  test "Type 2: hvcurveto alternates and takes a final extra delta" do
    cmds = run_type2([0, 0, {:op, 21}, 10, 20, 30, 40, 50, 60, 70, 80, 5, {:op, 31}, {:op, 14}])

    assert [
             {:move, 0, 0},
             {:curve, 10, 0, 30, 30, 30, 70},
             {:curve, 30, 120, 90, 190, 170, 195},
             :close
           ] = cmds
  end

  test "Type 2: local subroutines use the bias" do
    subr = cs([0, 100, {:op, 5}, {:op, 11}])
    # bias for fewer than 1240 subrs is 107: index 0 is called as -107
    cmds = run_type2([10, 10, {:op, 21}, -107, {:op, 10}, {:op, 14}], [subr])
    assert cmds == [{:move, 10, 10}, {:line, 10, 110}, :close]
  end

  test "Type 2: flex draws two curves" do
    cmds =
      run_type2([
        0,
        0,
        {:op, 21},
        10,
        0,
        10,
        5,
        10,
        0,
        10,
        0,
        10,
        -5,
        10,
        0,
        50,
        {:esc, 35},
        {:op, 14}
      ])

    assert [{:move, 0, 0}, {:curve, 10, 0, 20, 5, 30, 5}, {:curve, 40, 5, 50, 0, 60, 0}, :close] =
             cmds
  end

  test "Type 2: hhcurveto with leading dy and vvcurveto with leading dx" do
    assert [{:move, 0, 0}, {:curve, 10, 3, 30, 33, 60, 33}, :close] =
             run_type2([0, 0, {:op, 21}, 3, 10, 20, 30, 30, {:op, 27}, {:op, 14}])

    assert [{:move, 0, 0}, {:curve, 3, 10, 23, 40, 23, 80}, :close] =
             run_type2([0, 0, {:op, 21}, 3, 10, 20, 30, 40, {:op, 26}, {:op, 14}])
  end

  defp build_cff(charstrings) do
    header = <<1, 0, 4, 4>>
    names = index(["Test"])
    strings = index([])
    gsubrs = index([])
    cs_index = index(charstrings)

    # Top DICT: CharStrings offset (op 17) as a 5-byte int so its size is fixed
    top_len = byte_size(index([<<29, 0::32, 17>>]))

    cs_offset =
      byte_size(header) + byte_size(names) + top_len + byte_size(strings) + byte_size(gsubrs)

    top = index([<<29, cs_offset::32, 17>>])

    header <> names <> top <> strings <> gsubrs <> cs_index
  end

  test "CFF: parses a minimal font with the ISOAdobe charset" do
    notdef = cs([{:op, 14}])
    space = cs([250, {:op, 14}])
    exclam = cs([0, 0, {:op, 21}, 100, 0, 0, 700, -100, 0, {:op, 5}, {:op, 14}])
    {:ok, cff} = CFF.parse(build_cff([notdef, space, exclam]))

    assert cff.num_glyphs == 3
    assert CFF.name_gid(cff, "exclam") == 2
    assert CFF.glyph(cff, 1) == []

    assert [{:move, 0, 0}, {:line, x1, 0}, {:line, x2, y2}, {:line, 0, y3}, :close] =
             cff |> CFF.glyph(2) |> norm()

    assert_in_delta x1, 0.1, 1.0e-9
    assert_in_delta x2, 0.1, 1.0e-9
    assert_in_delta y2, 0.7, 1.0e-9
    assert_in_delta y3, 0.7, 1.0e-9

    # standard encoding: code 33 is "exclam"
    assert CFF.code_gid(cff, 33) == 2
    assert Program.parse(build_cff([notdef, space, exclam])).kind == :cff
  end

  # ---------------------------------------------------------------- Type 1

  defp t1_num(v) when v >= -107 and v <= 107, do: <<v + 139>>

  defp t1_num(v) when v >= 108 and v <= 1131 do
    v = v - 108
    <<div(v, 256) + 247, rem(v, 256)>>
  end

  defp t1_num(v) when v <= -108 and v >= -1131 do
    v = -v - 108
    <<div(v, 256) + 251, rem(v, 256)>>
  end

  defp t1_num(v), do: <<255, v::signed-32>>

  defp t1cs(items),
    do:
      IO.iodata_to_binary(
        Enum.map(items, fn
          i when is_integer(i) -> t1_num(i)
          {:op, o} -> <<o>>
          {:esc, o} -> <<12, o>>
        end)
      )

  defp encrypt(plain, r) do
    {out, _} =
      for <<p <- plain>>, reduce: {[], r} do
        {acc, r} ->
          c = bxor(p, r >>> 8)
          {[c | acc], band((c + r) * 52845 + 22719, 0xFFFF)}
      end

    out |> Enum.reverse() |> :erlang.list_to_binary()
  end

  defp build_type1(glyphs, subrs) do
    enc_cs = fn bytes -> encrypt(<<0, 0, 0, 0>> <> bytes, 4330) end

    subr_part =
      subrs
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        e = enc_cs.(s)
        "dup #{i} #{byte_size(e)} RD " <> e <> " NP\n"
      end)

    cs_part =
      Enum.map(glyphs, fn {name, s} ->
        e = enc_cs.(s)
        "/#{name} #{byte_size(e)} RD " <> e <> " ND\n"
      end)

    private =
      IO.iodata_to_binary([
        "dup /Private 8 dict dup begin\n/RD {string currentfile exch readstring pop} executeonly def\n",
        "/lenIV 4 def\n/Subrs #{length(subrs)} array\n",
        subr_part,
        "ND\n2 index /CharStrings #{length(glyphs)} dict dup begin\n",
        cs_part,
        "end\nend\nreadonly put\nnoaccess put\ndup /FontName get exch definefont pop\nmark currentfile closefile\n"
      ])

    clear = """
    %!PS-AdobeFont-1.0: Test 001.000
    /FontMatrix [0.001 0 0 0.001 0 0] readonly def
    /Encoding 256 array
    0 1 255 {1 index exch /.notdef put} for
    dup 65 /A put
    dup 66 /B put
    readonly def
    currentfile eexec
    """

    clear <>
      encrypt(<<1, 2, 3, 4>> <> private, 55665) <>
      "\n" <> String.duplicate("0", 64) <> "\ncleartomark\n"
  end

  test "Type 1: eexec program with hsbw, lines, closepath and the built-in encoding" do
    a =
      t1cs([
        50,
        600,
        {:op, 13},
        0,
        0,
        {:op, 21},
        500,
        0,
        {:op, 5},
        0,
        700,
        {:op, 5},
        {:op, 9},
        {:op, 14}
      ])

    {:ok, t1} = Type1.parse(build_type1([{"A", a}], []))

    assert t1.encoding[65] == "A"

    assert [{:move, 0.05, 0}, {:line, x1, 0}, {:line, x2, y2}, :close] =
             t1 |> Type1.glyph("A") |> norm()

    assert_in_delta x1, 0.55, 1.0e-9
    assert_in_delta x2, 0.55, 1.0e-9
    assert_in_delta y2, 0.7, 1.0e-9
    assert Type1.glyph(t1, "missing") == nil
  end

  test "Type 1: flex through OtherSubrs 0/1/2 becomes two curves" do
    # the standard flex subroutines
    subr0 = t1cs([3, 0, {:esc, 16}, {:esc, 17}, {:esc, 17}, {:esc, 33}, {:op, 11}])
    subr1 = t1cs([0, 1, {:esc, 16}, {:op, 11}])
    subr2 = t1cs([0, 2, {:esc, 16}, {:op, 11}])

    flex_points =
      [{30, 0}, {-20, 0}, {10, 5}, {10, 0}, {10, 0}, {10, -5}, {10, 0}]
      |> Enum.flat_map(fn {dx, dy} -> [dx, dy, {:op, 21}, 2, {:op, 10}] end)

    glyph =
      t1cs(
        [0, 600, {:op, 13}, 0, 0, {:op, 21}, 1, {:op, 10}] ++
          flex_points ++ [50, 60, 0, 0, {:op, 10}, {:op, 9}, {:op, 14}]
      )

    {:ok, t1} = Type1.parse(build_type1([{"A", glyph}], [subr0, subr1, subr2]))

    assert [{:move, 0, 0}, {:curve, _, _, _, _, x3, y3}, {:curve, _, _, _, _, x6, y6}, :close] =
             t1 |> Type1.glyph("A") |> norm()

    assert_in_delta x3, 0.03, 1.0e-9
    assert_in_delta y3, 0.005, 1.0e-9
    assert_in_delta x6, 0.06, 1.0e-9
    assert_in_delta y6, 0.0, 1.0e-9
  end

  test "Type 1: seac composes a base and an accent" do
    # StandardEncoding: 65 = A, 194 = acute
    base = t1cs([0, 600, {:op, 13}, 0, 0, {:op, 21}, 100, 0, {:op, 5}, {:op, 9}, {:op, 14}])
    acute = t1cs([0, 300, {:op, 13}, 0, 500, {:op, 21}, 50, 0, {:op, 5}, {:op, 9}, {:op, 14}])
    composite = t1cs([0, 600, {:op, 13}, 0, 200, 100, 65, 194, {:esc, 6}])

    {:ok, t1} =
      Type1.parse(build_type1([{"A", base}, {"acute", acute}, {"Aacute", composite}], []))

    assert [{:move, 0, 0}, {:line, 0.1, 0}, :close, {:move, ax, ay}, {:line, _, _}, :close] =
             t1 |> Type1.glyph("Aacute") |> norm()

    assert_in_delta ax, 0.2, 1.0e-9
    assert_in_delta ay, 0.6, 1.0e-9
  end

  test "Type 1: PFB segments are unwrapped" do
    a = t1cs([0, 600, {:op, 13}, 0, 0, {:op, 21}, 10, 10, {:op, 5}, {:op, 14}])
    pfa = build_type1([{"A", a}], [])
    {pos, _} = :binary.match(pfa, "eexec")
    ascii = binary_part(pfa, 0, pos + 6)
    binary = binary_part(pfa, pos + 6, byte_size(pfa) - pos - 6)

    pfb =
      <<0x80, 1, byte_size(ascii)::little-32>> <>
        ascii <> <<0x80, 2, byte_size(binary)::little-32>> <> binary <> <<0x80, 3>>

    assert Program.parse(pfb).kind == :type1
  end

  test "garbage never raises" do
    for bytes <- [
          <<>>,
          "junk",
          <<0, 1, 0, 0, 0, 9>>,
          <<1, 0, 4, 4, 0>>,
          "%!PS-AdobeFont eexec \xFF\xFF"
        ] do
      assert Program.parse(bytes) == nil or match?(%Program{}, Program.parse(bytes))
    end

    assert CFF.parse(<<1, 0, 4, 4, 0, 5, 1>>) == :error
    assert Type1.parse("no program") == :error
    assert TrueType.glyph(%TrueType{}, 3) == nil
  end
end
