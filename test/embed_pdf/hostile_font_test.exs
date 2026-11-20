defmodule EmbedPdf.HostileFontTest do
  # Fonts and CMaps built to exhaust memory or time: each must come back
  # quickly with a bounded result. Not async: two tests change the font
  # cache settings of the application.
  use ExUnit.Case, async: false
  import Bitwise

  alias EmbedPdf.Font
  alias EmbedPdf.Font.{CFF, CMap, Program, TrueType, Type1}

  @cache :embed_pdf_font_programs

  # runs `fun` apart from the test, killing it when it does not return
  defp bounded(fun, timeout \\ 5_000) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> flunk("still running after #{timeout} ms")
    end
  end

  # ---------------------------------------------------------------- builders

  # a classic PDF from `[{number, body}]`
  defp pdf(objects) do
    {body, offsets} =
      Enum.reduce(objects, {"%PDF-1.7\n", %{}}, fn {n, b}, {acc, offs} ->
        {acc <> "#{n} 0 obj\n" <> b <> "\nendobj\n", Map.put(offs, n, byte_size(acc))}
      end)

    max = objects |> Enum.map(&elem(&1, 0)) |> Enum.max()

    entries =
      for i <- 0..max do
        case offsets[i] do
          nil -> "0000000000 65535 f \n"
          off -> String.pad_leading(Integer.to_string(off), 10, "0") <> " 00000 n \n"
        end
      end

    body <>
      "xref\n0 #{max + 1}\n" <>
      Enum.join(entries) <>
      "trailer\n<</Size #{max + 1} /Root 1 0 R>>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end

  defp stream(dict, data),
    do: "<<#{dict} /Length #{byte_size(data)}>>\nstream\n" <> data <> "\nendstream"

  # one page showing `content` with the font objects `extra` (numbered from 10)
  defp page_doc(content, extra) do
    bytes =
      pdf(
        [
          {1, "<</Type/Catalog /Pages 2 0 R>>"},
          {2, "<</Type/Pages /Kids [3 0 R] /Count 1>>"},
          {3,
           "<</Type/Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R " <>
             "/Resources <</Font <</F1 10 0 R>>>>>>"},
          {4, stream("", content)}
        ] ++ extra
      )

    {:ok, doc} = EmbedPdf.open(bytes)
    doc
  end

  defp sfnt(tables) do
    n = length(tables)

    {records, data, _} =
      Enum.reduce(tables, {<<>>, <<>>, 12 + 16 * n}, fn {tag, bin}, {r, d, off} ->
        {<<r::binary, tag::binary-4, 0::32, off::32, byte_size(bin)::32>>, d <> bin,
         off + byte_size(bin)}
      end)

    <<0, 1, 0, 0, n::16, 0::48>> <> records <> data
  end

  # `records` encoding records that all point at one subtable
  defp cmap_table(records, subtable) do
    header = 4 + 8 * records
    recs = for r <- 0..(records - 1), into: <<>>, do: <<3::16, 100 + r::16, header::32>>
    <<0::16, records::16>> <> recs <> subtable
  end

  # a glyf font from glyph descriptions (each padded to an even length)
  defp glyf_font(glyphs) do
    glyphs = Enum.map(glyphs, &if(rem(byte_size(&1), 2) == 1, do: &1 <> <<0>>, else: &1))

    {loca, _} =
      Enum.reduce(glyphs, {<<0::32>>, 0}, fn g, {l, off} ->
        {<<l::binary, off + byte_size(g)::32>>, off + byte_size(g)}
      end)

    head =
      :binary.copy(<<0>>, 18) <>
        <<1000::16>> <> :binary.copy(<<0>>, 30) <> <<1::signed-16, 0::16>>

    maxp = <<0x00010000::32, length(glyphs)::16>>

    sfnt([
      {"head", head},
      {"maxp", maxp},
      {"loca", loca},
      {"glyf", IO.iodata_to_binary(glyphs)}
    ])
  end

  defp triangle,
    do:
      <<1::signed-16, 0::64, 2::16, 0::16, 1, 1, 1, 0::16, 10::signed-16, 0::signed-16, 0::16,
        0::16, 10::16>>

  defp index([]), do: <<0::16>>

  defp index(items) do
    {offsets, last} = Enum.map_reduce(items, 1, fn item, off -> {off, off + byte_size(item)} end)

    <<length(items)::16, 4, for(o <- offsets ++ [last], into: <<>>, do: <<o::32>>)::binary,
      IO.iodata_to_binary(items)::binary>>
  end

  # a CID-keyed CFF with one glyph; `tail.(offset)` builds what follows the
  # CharStrings (FDSelect first) and returns `{bytes, fd_array_offset | nil}`
  defp cid_cff(tail) do
    header = <<1, 0, 4, 4>>
    names = index(["A"])
    charstrings = index([<<14>>])
    top_len = byte_size(index([:binary.copy(<<0>>, 25)]))
    cs_off = byte_size(header) + byte_size(names) + top_len + 2 + 2
    fd_select_off = cs_off + byte_size(charstrings)
    {rest, fd_array_off} = tail.(fd_select_off)

    top =
      <<139, 139, 139, 12, 30, 29, cs_off::32, 17, 29, fd_array_off || 0::32, 12, 36, 29,
        fd_select_off::32, 12, 37>>

    header <> names <> index([top]) <> <<0::16>> <> <<0::16>> <> charstrings <> rest
  end

  defp encrypt(plain, r) do
    {out, _} =
      for <<p <- plain>>, reduce: {[], r} do
        {acc, r} ->
          c = bxor(p, r >>> 8)
          {[c | acc], band((c + r) * 52845 + 22719, 0xFFFF)}
      end

    out |> Enum.reverse() |> :erlang.list_to_binary()
  end

  # a Type 1 program with the glyphs `[{name, charstring}]` after `clear` text
  defp type1(clear, glyphs) do
    entries =
      for {name, cs} <- glyphs, into: "" do
        e = encrypt(<<0, 0, 0, 0>> <> cs, 4330)
        "/#{name} #{byte_size(e)} RD " <> e <> " ND\n"
      end

    private =
      "/lenIV 4 def\n/CharStrings #{length(glyphs)} dict dup begin\n" <> entries <> "end\n"

    clear <> "\ncurrentfile eexec\n" <> encrypt(<<1, 2, 3, 4>> <> private, 55665)
  end

  # ---------------------------------------------------------------- CMaps

  test "11: an empty codespace range does not stop the string splitter" do
    cmap = "begincmap\n1 begincodespacerange\n<> <>\nendcodespacerange\nendcmap"

    doc =
      page_doc("BT /F1 12 Tf (ABCD) Tj ET", [
        {10,
         "<</Type/Font /Subtype/Type0 /BaseFont/X /Encoding 11 0 R /DescendantFonts [12 0 R]>>"},
        {11, stream("/Type/CMap", cmap)},
        {12, "<</Type/Font /Subtype/CIDFontType2 /BaseFont/X>>"}
      ])

    assert is_binary(bounded(fn -> EmbedPdf.text(doc, 0) end))
    assert is_binary(bounded(fn -> EmbedPdf.render_svg(doc, 0) |> IO.iodata_to_binary() end))

    # ranges that no code can have are dropped at parse time
    parsed =
      CMap.parse("2 begincodespacerange <> <> <0000000000> <FFFFFFFFFF> endcodespacerange")

    assert parsed.codespace == []
    assert CMap.codes(parsed, "ABCD") == [{0x4142, 2}, {0x4344, 2}]

    # and the splitter itself always takes at least one byte
    stuck = %CMap{codespace: [{0, 0, 0}]}
    assert bounded(fn -> CMap.codes(stuck, "ABC") end) == [{?A, 1}, {?B, 1}, {?C, 1}]

    # every code is tried against every range: only so many are kept
    many = for i <- 1..5_000, into: "", do: "<#{Integer.to_string(0x1000 + i, 16)}> <FFFF> "
    assert length(CMap.parse("begincodespacerange #{many} endcodespacerange").codespace) <= 64

    # a well-formed mixed-width codespace is unchanged
    good = CMap.parse("2 begincodespacerange <00> <80> <8140> <FEFE> endcodespacerange")
    assert good.codespace == [{1, 0, 0x80}, {2, 0x8140, 0xFEFE}]
    assert CMap.codes(good, <<0x41, 0x81, 0x40>>) == [{0x41, 1}, {0x8140, 2}]
  end

  test "25: unknown predefined CMap names leave nothing behind" do
    tag = System.unique_integer([:positive])
    names = for i <- 1..300, do: "Zz#{tag}x#{i}"
    text = for n <- names, into: "", do: "/#{n} usecmap\n"

    bounded(fn ->
      CMap.parse(text)
      Enum.each(names, &CMap.predefined/1)
    end)

    for name <- names do
      assert :persistent_term.get({CMap, name}, :missing) == :missing
    end

    assert CMap.predefined("../../mix.exs") == nil
    assert CMap.predefined("/etc/passwd") == nil
    assert CMap.predefined("Identity-H" <> <<0>> <> "x") == nil

    # the shipped ones still load, and stay cached
    assert %CMap{codespace: [_ | _]} = CMap.predefined("90ms-RKSJ-H")
    assert %CMap{} = :persistent_term.get({CMap, "90ms-RKSJ-H"})
  end

  # ---------------------------------------------------------------- /W

  test "17: /W ranges are not expanded past the CIDs a font can have" do
    w = for i <- 0..999, into: "", do: "#{i * 5001} #{i * 5001 + 5000} 500 "

    doc =
      page_doc("BT /F1 12 Tf <0041> Tj ET", [
        {10,
         "<</Type/Font /Subtype/Type0 /BaseFont/X /Encoding /Identity-H /DescendantFonts [11 0 R]>>"},
        {11, "<</Type/Font /Subtype/CIDFontType2 /BaseFont/X /DW 250 /W [#{w}]>>"}
      ])

    font = bounded(fn -> Font.load(doc, {:ref, 10, 0}) end)
    assert map_size(font.widths) <= 65_537
    assert length(font.widths.ranges) <= 64

    # expanded ranges and compact ones both answer
    assert [{_, 0x41, _, 0.5, 2}] = Font.decode(font, <<0x41::16>>)
    assert [{_, 0xFFFF, _, 0.5, 2}] = Font.decode(font, <<0xFFFF::16>>)

    # an ordinary /W is expanded as before
    doc =
      page_doc("BT /F1 12 Tf <0041> Tj ET", [
        {10,
         "<</Type/Font /Subtype/Type0 /BaseFont/X /Encoding /Identity-H /DescendantFonts [11 0 R]>>"},
        {11, "<</Type/Font /Subtype/CIDFontType2 /BaseFont/X /W [1 3 500 7 [600 700] 10 9 800]>>"}
      ])

    assert Font.load(doc, {:ref, 10, 0}).widths == %{
             1 => 0.5,
             2 => 0.5,
             3 => 0.5,
             7 => 0.6,
             8 => 0.7
           }
  end

  # ---------------------------------------------------------------- TrueType

  test "18: cmap format 12 groups shared by several records stay within the budget" do
    groups = 50

    subtable =
      <<12::16, 0::16, 0::32, 0::32, groups::32>> <>
        for i <- 0..(groups - 1),
            into: <<>>,
            do: <<i * 0x20000::32, i * 0x20000 + 0x10000::32, 1::32>>

    font = sfnt([{"cmap", cmap_table(4, subtable)}])
    assert byte_size(font) < 1_000

    {:ok, tt} = bounded(fn -> TrueType.parse(font) end)
    assert tt.cmaps |> Map.values() |> Enum.map(&map_size/1) |> Enum.sum() <= 524_288
    # what was read is right: group 0 maps code c to glyph 1 + c
    assert TrueType.cmap_lookup(tt, {3, 100}, 5) == 6

    # many records over one byte-encoding subtable
    font =
      sfnt([{"cmap", cmap_table(5_000, <<0::16, 262::16, 0::16>> <> :binary.copy(<<7>>, 256))}])

    {:ok, tt} = bounded(fn -> TrueType.parse(font) end)
    assert map_size(tt.cmaps) <= 64
    assert TrueType.cmap_lookup(tt, {3, 100}, 65) == 7
  end

  test "19: overlapping cmap format 4 segments are not walked again and again" do
    seg = 2_000
    words = fn v -> :binary.copy(<<v::16>>, seg) end

    subtable =
      <<4::16, 0::16, 0::16, seg * 2::16, 0::48>> <>
        words.(0xFFFE) <> <<0::16>> <> words.(1) <> words.(1) <> words.(0)

    {:ok, tt} = bounded(fn -> TrueType.parse(sfnt([{"cmap", cmap_table(4, subtable)}])) end)
    assert tt.cmaps |> Map.values() |> Enum.map(&map_size/1) |> Enum.sum() <= 524_288
    assert TrueType.cmap_lookup(tt, {3, 100}, 65) == 66
  end

  test "20: composite glyphs that fan out, and contours that overlap, have no outline" do
    levels = 9

    glyphs =
      for i <- 0..(levels - 1) do
        if i == levels - 1 do
          triangle()
        else
          <<-1::signed-16, 0::64>> <>
            for c <- 1..8,
                into: <<>>,
                do: <<if(c == 8, do: 0x0002, else: 0x0022)::16, i + 1::16, 0, 0>>
        end
      end

    {:ok, tt} = TrueType.parse(glyf_font(glyphs))
    assert bounded(fn -> TrueType.glyph(tt, 0) end) == nil
    # the lower levels fit the budget and still draw
    assert [{:move, _, _} | _] = TrueType.glyph(tt, levels - 1)
    assert [{:move, _, _} | _] = TrueType.glyph(tt, levels - 2)

    # one simple glyph of 65,536 points whose end points go back and forth
    contours = 16_001
    ends = for i <- 1..contours, into: <<>>, do: <<if(rem(i, 2) == 1, do: 0xFFFF, else: 0)::16>>
    {:ok, tt} = TrueType.parse(glyf_font([<<contours::signed-16, 0::64>> <> ends <> <<0::16>>]))
    assert bounded(fn -> TrueType.glyph(tt, 0) end) == nil
  end

  # ---------------------------------------------------------------- charstrings

  test "21: Type 2 charstrings cannot grow the operand stack through subroutines" do
    pushes = :binary.copy(<<139>>, 60_000) <> <<11>>

    ctx = %{
      gsubrs: {<<>>, {}},
      subrs: {pushes, {1, byte_size(pushes) + 1}},
      seac: fn _ -> nil end
    }

    # (-107 is subroutine 0 with the bias of a small INDEX)
    cs = :binary.copy(<<32, 10>>, 400) <> <<14>>

    assert bounded(fn -> CFF.Type2.run(cs, ctx) end) == :error
    assert bounded(fn -> CFF.Type2.width(cs, ctx) end) == :unknown

    # operands that are consumed still run out of budget
    loop = :binary.copy(<<139, 12, 18>>, 20_000) <> <<11>>
    ctx = %{ctx | subrs: {loop, {1, byte_size(loop) + 1}}}
    assert bounded(fn -> CFF.Type2.run(cs, ctx) end) == :error

    # squaring an integer over and over stays a machine number
    square = <<28, 0x7FFF::16>> <> :binary.copy(<<12, 27, 12, 24>>, 64) <> <<14>>
    assert bounded(fn -> CFF.Type2.run(square, ctx) end) in [:error, {:ok, []}]

    # 48 operands, the limit of the specification, are fine
    line = :binary.copy(<<140, 139>>, 24) <> <<5, 14>>
    assert {:ok, cmds} = CFF.Type2.run(<<139, 139, 21>> <> line, ctx)
    assert Enum.count(cmds, &match?({:line, _, _}, &1)) == 24
  end

  test "21: Type 1 charstrings cannot grow the operand stack through subroutines" do
    pushes = :binary.copy(<<139>>, 60_000) <> <<11>>
    ctx = %{subrs: {pushes}, seac: fn _ -> nil end}
    cs = :binary.copy(<<139, 10>>, 400) <> <<14>>

    assert bounded(fn -> Type1.Charstring.run(cs, ctx) end) == :error

    # `div` consumes its operands: the budget ends it
    loop = :binary.copy(<<139, 140, 12, 12>>, 20_000) <> <<11>>
    assert bounded(fn -> Type1.Charstring.run(cs, %{ctx | subrs: {loop}}) end) == :error
  end

  # ---------------------------------------------------------------- CFF tables

  test "22: FDSelect ranges that go back and forth give one byte per glyph" do
    ranges = for i <- 0..7_999, into: <<>>, do: <<if(rem(i, 2) == 0, do: 0, else: 0xFFFF)::16, 0>>
    font = cid_cff(fn _ -> {<<3, 8_000::16>> <> ranges <> <<0xFFFF::16>>, nil} end)

    {:ok, cff} = bounded(fn -> CFF.parse(font) end)
    assert cff.num_glyphs == 1
    assert cff.fd_select == <<0>>
    assert CFF.glyph(cff, 0) == []
  end

  test "22: font DICTs sharing one large Subrs INDEX are bounded" do
    fds = 3_000

    font =
      cid_cff(fn fd_select_off ->
        fd_select = <<0, 0>>
        fd_array_off = fd_select_off + byte_size(fd_select)

        private_off =
          fd_array_off + byte_size(index(List.duplicate(:binary.copy(<<0>>, 11), fds)))

        fd = <<29, 6::32, 29, private_off::32, 18>>
        # Private DICT: Subrs right after it, an INDEX of 65,535 empty entries
        private = <<29, 6::32, 19>>
        subrs = <<0xFFFF::16, 1>> <> :binary.copy(<<1>>, 0x10000)
        {fd_select <> index(List.duplicate(fd, fds)) <> private <> subrs, fd_array_off}
      end)

    {:ok, cff} = bounded(fn -> CFF.parse(font) end)
    assert cff.cid?
    assert tuple_size(cff.fds) <= 256
    kept = cff.fds |> Tuple.to_list() |> Enum.map(&CFF.index_count(&1.subrs)) |> Enum.sum()
    assert kept > 0 and kept <= 262_144
  end

  # ---------------------------------------------------------------- program cache

  defp truetype_doc(font_stream) do
    page_doc("BT /F1 12 Tf (A) Tj ET", [
      {10, "<</Type/Font /Subtype/TrueType /BaseFont/X /FontDescriptor 11 0 R>>"},
      {11, "<</Type/FontDescriptor /FontName/X /Flags 4 /FontFile2 12 0 R>>"},
      {12, font_stream}
    ])
  end

  test "26: oversized programs are not parsed and oversized entries are not cached" do
    huge = <<0, 1, 0, 0>> <> :binary.copy(<<0>>, 30_000_001)
    assert bounded(fn -> Program.parse(huge) end) == nil

    previous = Application.get_env(:embedpdf_ex, :font_cache_bytes)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:embedpdf_ex, :font_cache_bytes, previous),
        else: Application.delete_env(:embedpdf_ex, :font_cache_bytes)
    end)

    unique_font = fn -> glyf_font([triangle(), <<System.unique_integer([:positive])::64>>]) end
    load = fn font -> Font.load(truetype_doc(stream("", font)), {:ref, 10, 0}).program end
    cached? = fn id -> :ets.lookup(@cache, {:program, id}) != [] end
    :ets.delete_all_objects(@cache)
    font = unique_font.()

    # an entry over half the budget is not kept
    Application.put_env(:embedpdf_ex, :font_cache_bytes, 64)
    %Program{id: id} = load.(font)
    refute cached?.(id)

    Application.put_env(:embedpdf_ex, :font_cache_bytes, 64_000_000)
    assert %Program{id: ^id} = load.(font)
    assert cached?.(id)
    assert [{_, cost}] = :ets.lookup(@cache, :"$bytes")
    assert cost >= byte_size(font)

    # room for two such fonts: the third empties the table and starts over
    Application.put_env(:embedpdf_ex, :font_cache_bytes, div(5 * cost, 2))
    %Program{id: second} = load.(unique_font.())
    assert cached?.(id) and cached?.(second)
    %Program{id: third} = load.(unique_font.())
    assert cached?.(third)
    refute cached?.(id) or cached?.(second)
    assert :ets.lookup(@cache, :"$bytes") == [{:"$bytes", cost}]
  end

  test "27: programs and outlines are cached under a SHA-256 of the font stream" do
    font = glyf_font([triangle(), <<System.unique_integer([:positive])::64>>])
    packed = :zlib.compress(font)

    # the same stored bytes decoded another way are another font: loading
    # this one first must not answer for the real one
    broken =
      truetype_doc(
        stream("/Filter /FlateDecode /DecodeParms <</Predictor 12 /Columns 3>>", packed)
      )

    assert Font.load(broken, {:ref, 10, 0}).program == nil

    loaded = Font.load(truetype_doc(stream("/Filter /FlateDecode", packed)), {:ref, 10, 0})
    assert %Program{kind: :truetype, id: id} = loaded.program
    assert byte_size(id) == 32

    # the same font in another document shares the entry, another font does not
    again = Font.load(truetype_doc(stream("/Filter /FlateDecode", packed)), {:ref, 10, 0})
    assert again.program.id == id

    other = glyf_font([triangle(), <<System.unique_integer([:positive])::64>>])
    other = Font.load(truetype_doc(stream("", other)), {:ref, 10, 0})
    assert byte_size(other.program.id) == 32 and other.program.id != id

    # outlines are stored under the same id (glyph 0 through its code)
    font = %Font{type: "Type0", cid_type: "CIDFontType2", program: loaded.program}
    assert [{:move, _, _} | _] = cmds = Font.glyph_outline(font, {0, 0, "", 0.0, 2})
    assert :ets.lookup(@cache, {:outline, id, 0}) == [{{:outline, id, 0}, cmds}]
  end

  # ---------------------------------------------------------------- Type 1 text

  test "29: a clear text made of /FontMatrix keys parses in linear time" do
    glyphs = [{"a", <<139, 239, 13, 14>>}]
    clear = "%!PS-AdobeFont-1.0\n" <> String.duplicate("/FontMatrix[", 40_000)

    {:ok, t1} = bounded(fn -> Type1.parse(type1(clear, glyphs)) end)
    assert t1.matrix == [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]
    assert_in_delta Type1.advance(t1, "a"), 0.1, 1.0e-9

    # the matrix is still found after a key that is not followed by one
    clear =
      "%!PS-AdobeFont-1.0\n% /FontMatrix below\n/FontMatrix [0.002 0 0 0.002 0 0] readonly def"

    {:ok, t1} = Type1.parse(type1(clear, glyphs))
    assert t1.matrix == [0.002, 0.0, 0.0, 0.002, 0.0, 0.0]

    # numbers of absurd length are not read as integers
    clear =
      "%!PS-AdobeFont-1.0\ndup " <> String.duplicate("9", 300_000) <> " /a put\ndup 65 /a put"

    private = "/lenIV " <> String.duplicate("9", 300_000) <> " def\n"
    {:ok, t1} = bounded(fn -> Type1.parse(type1(clear <> "\n", glyphs)) end)
    assert t1.encoding == %{65 => "a"}

    assert bounded(fn -> Type1.parse("eexec " <> encrypt(<<1, 2, 3, 4>> <> private, 55665)) end) ==
             :error
  end

  test "glyph names of absurd length are dropped from the encoding" do
    long = String.duplicate("a_", 200_000)

    doc =
      page_doc("BT /F1 12 Tf (AB) Tj ET", [
        {10,
         "<</Type/Font /Subtype/Type1 /BaseFont/Helvetica " <>
           "/Encoding <</Differences [65 /#{long} /B]>>>>"}
      ])

    font = bounded(fn -> Font.load(doc, {:ref, 10, 0}) end)
    assert Font.glyph_name(font, 65) == nil
    assert Font.glyph_name(font, 66) == "B"
    assert EmbedPdf.Font.GlyphList.to_unicode(long) == nil
    assert is_binary(bounded(fn -> EmbedPdf.text(doc, 0) end))
  end
end
