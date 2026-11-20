defmodule EmbedPdf.HostileStructureTest do
  @moduledoc """
  Files built to cost far more than their size: every case here used to hang
  or to allocate gigabytes. Each one has to come back, quickly, with a result
  of a sane size.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias EmbedPdf.{Destinations, Forms, Metadata, Outline}
  alias EmbedPdf.PDF.{Content, Document, Filter, NameTree, Parser, Xref}

  @head "%PDF-1.7\n1 0 obj\n<</Type/Catalog /Pages 2 0 R>>\nendobj\n" <>
          "2 0 obj\n<</Type/Pages /Kids [] /Count 0>>\nendobj\n"

  # runs `fun` in its own process: the result, or a failed test after 5 s
  defp bounded(fun) do
    task = Task.async(fun)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      other -> flunk("did not return within 5 s: #{inspect(other)}")
    end
  end

  # runs `fun` in a process that is killed if its heap passes `megabytes`
  defp within_heap(megabytes, fun) do
    parent = self()
    words = div(megabytes * 1_000_000, :erlang.system_info(:wordsize))
    limit = %{size: words, kill: true, error_logger: false}

    {pid, ref} =
      :erlang.spawn_opt(fn -> send(parent, {:result, self(), fun.()}) end, [
        :monitor,
        {:max_heap_size, limit}
      ])

    receive do
      {:result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("needed more than #{megabytes} MB of heap: #{inspect(reason)}")
    after
      5_000 ->
        Process.exit(pid, :kill)
        flunk("did not return within 5 s")
    end
  end

  # a file with a classic cross-reference table from `[{number, body}]`
  defp pdf(objects) do
    {body, offsets} =
      Enum.reduce(objects, {"%PDF-1.7\n", %{}}, fn {n, b}, {acc, offsets} ->
        {acc <> "#{n} 0 obj\n" <> b <> "\nendobj\n", Map.put(offsets, n, byte_size(acc))}
      end)

    max = objects |> Enum.map(&elem(&1, 0)) |> Enum.max()

    entries =
      for i <- 0..max, into: "" do
        case offsets[i] do
          nil -> "0000000000 65535 f \n"
          off -> String.pad_leading(Integer.to_string(off), 10, "0") <> " 00000 n \n"
        end
      end

    body <>
      "xref\n0 #{max + 1}\n" <>
      entries <>
      "trailer\n<</Size #{max + 1} /Root 1 0 R>>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end

  defp stream(dict, data),
    do: "<<#{dict} /Length #{byte_size(data)}>>\nstream\n" <> data <> "\nendstream"

  # a file whose cross-reference is a stream with the given entries
  defp xref_stream_pdf(dict, data) do
    @head <>
      "9 0 obj\n" <>
      stream("/Type/XRef /Root 1 0 R #{dict}", data) <>
      "\nendobj\nstartxref\n#{byte_size(@head)}\n%%EOF\n"
  end

  # opens, or fails with an error: either way it comes back
  defp returns?(bytes), do: elem(bounded(fn -> Document.open(bytes) end), 0) in [:ok, :error]

  defp open!(bytes) do
    assert {:ok, doc} = bounded(fn -> Document.open(bytes) end)
    doc
  end

  describe "cross-reference" do
    test "1: /Size and /Index of a cross-reference stream do not drive the loop" do
      for dict <- [
            "/Size 1000000000000 /W [1 2 1]",
            "/Size 5 /W [1 2 1] /Index [0 1000000000000]"
          ] do
        assert {:ok, doc} = bounded(fn -> Document.open(xref_stream_pdf(dict, "")) end)
        assert map_size(doc.objects) < 10
      end

      huge = 1_000_000_000_000

      assert bounded(fn -> Xref.parse_xref_stream(%{"Size" => huge, "W" => [1, 2, 1]}, "") end) ==
               %{}

      # no width, and widths no offset needs
      assert Xref.parse_xref_stream(%{"Size" => huge, "W" => [0, 0, 0]}, <<1, 2, 3>>) == %{}
      assert Xref.parse_xref_stream(%{"Size" => 2, "W" => [1, 1_000_000, 1]}, <<1, 2, 3>>) == %{}
      assert Xref.parse_xref_stream(%{"Size" => 2, "W" => "x", "Index" => 7}, <<>>) == %{}
    end

    test "1: a real cross-reference stream reads as before" do
      data = <<0, 0::16, 255, 1, 300::16, 0, 2, 7::16, 3, 1, 9::16>>

      assert Xref.parse_xref_stream(%{"Size" => 3, "W" => [1, 2, 1]}, data) ==
               %{0 => :free, 1 => {:offset, 300, 0}, 2 => {:compressed, 7, 3}}

      assert Xref.parse_xref_stream(
               %{"Size" => 9, "W" => [1, 2, 1], "Index" => [5, 1, 8, 2]},
               data
             ) ==
               %{5 => :free, 8 => {:offset, 300, 0}, 9 => {:compressed, 7, 3}}

      # without a type field every entry is in use
      assert Xref.parse_xref_stream(%{"Size" => 2, "W" => [0, 2, 0]}, <<0, 9, 1, 0>>) ==
               %{0 => {:offset, 9, 0}, 1 => {:offset, 256, 0}}
    end

    test "2: sections that point at each other through /XRefStm and /Prev are read once" do
      width = 60
      base = byte_size(@head)

      sections =
        for i <- 0..63, into: "" do
          next = base + (i + 1) * width

          trailer =
            if i == 63,
              do: "<</Root 1 0 R>>",
              else: "<</Root 1 0 R /XRefStm #{next} /Prev #{next}>>"

          String.pad_trailing("xref\ntrailer\n" <> trailer, width - 1) <> "\n"
        end

      bytes = @head <> sections <> "startxref\n#{base}\n%%EOF\n"
      assert {:ok, doc} = bounded(fn -> Document.open(bytes) end)
      assert Document.page_count(doc) == 0
    end

    test "2: a chain of more sections than any file has stops" do
      width = 50
      base = byte_size(@head)

      sections =
        for i <- 0..2_999, into: "" do
          String.pad_trailing(
            "xref\ntrailer\n<</Root 1 0 R /Prev #{base + (i + 1) * width}>>",
            width - 1
          ) <> "\n"
        end

      bytes = @head <> sections <> "startxref\n#{base}\n%%EOF\n"
      assert {:ok, _doc} = bounded(fn -> Document.open(bytes) end)
    end
  end

  describe "cross-reference, not in the audit" do
    test "a table followed by anything but a subsection or a trailer ends there" do
      for junk <- [
            "junk here\n",
            "0 0\n(\n",
            "0 1\n0000000000 65535 f \n0000000009 00000 n \nn n\n"
          ] do
        bytes =
          @head <>
            "xref\n" <>
            junk <> "trailer\n<</Root 1 0 R>>\nstartxref\n#{byte_size(@head)}\n%%EOF\n"

        assert {:ok, doc} = bounded(fn -> Document.open(bytes) end)
        assert map_size(doc.objects) == 2
      end
    end

    test "a few bytes of cross-reference stream do not announce millions of objects" do
      # 20 MB of one-byte entries, every one an object at offset 0
      data = :zlib.compress(:binary.copy(<<1>>, 20_000_000))
      bytes = xref_stream_pdf("/Size 20000000 /W [1 0 0] /Filter /FlateDecode", data)
      assert byte_size(bytes) < 30_000

      assert {entries, _trailer, _} = bounded(fn -> Xref.load(bytes) end)
      assert map_size(entries) <= 65_536
      assert returns?(bytes)
    end

    test "an object stream holds the objects its header lists, not as many as /N says" do
      for {first, data} <- [
            {0, ""},
            {3, "xyz[1]"},
            {4, "7 x [1]"},
            {5, "-7 0 [1]"},
            {4, "7 9 [1]"}
          ] do
        bytes =
          @head <>
            "5 0 obj\n" <>
            stream("/Type/ObjStm /N 1000000000000 /First #{first}", data) <>
            "\nendobj\ntrailer\n<</Root 1 0 R>>\n"

        assert {:ok, doc} = bounded(fn -> Document.open(bytes) end)
        assert map_size(doc.objects) == 3
      end

      bytes =
        @head <>
          "5 0 obj\n" <>
          stream("/Type/ObjStm /N 1000000000000 /First 8", "7 0 8 4 [1] (b)") <>
          "\nendobj\ntrailer\n<</Root 1 0 R>>\n"

      assert {:ok, doc} = bounded(fn -> Document.open(bytes) end)
      assert doc.objects[7] == [1] and doc.objects[8] == {:string, "b"}
    end
  end

  describe "page tree" do
    test "3: a tree whose nodes list the next node twice has no more pages than leaves" do
      levels = 48

      nodes =
        for i <- 0..(levels - 1) do
          if i == levels - 1,
            do: {10 + i, "<</Type/Page /MediaBox [0 0 10 10]>>"},
            else: {10 + i, "<</Type/Pages /Kids [#{11 + i} 0 R #{11 + i} 0 R]>>"}
        end

      doc = open!(pdf([{1, "<</Type/Catalog /Pages 10 0 R>>"}] ++ nodes))
      assert Document.page_count(doc) == 2
    end

    test "3: other generation numbers do not make a node new" do
      nodes =
        for i <- 0..39 do
          if i == 39,
            do: {10 + i, "<</Type/Page /MediaBox [0 0 10 10]>>"},
            else: {10 + i, "<</Type/Pages /Kids [#{11 + i} 0 R #{11 + i} 1 R #{11 + i} 2 R]>>"}
        end

      doc = open!(pdf([{1, "<</Type/Catalog /Pages 10 0 R>>"}] ++ nodes))
      assert Document.page_count(doc) == 3
    end

    test "3: the page list is cut at the page limit" do
      kids = String.duplicate("3 0 R ", Document.max_pages() + 50)

      doc =
        open!(
          pdf([
            {1, "<</Type/Catalog /Pages 2 0 R>>"},
            {2, "<</Type/Pages /Kids [#{kids}]>>"},
            {3, "<</Type/Page /MediaBox [0 0 10 10]>>"}
          ])
        )

      assert Document.page_count(doc) == Document.max_pages()
    end

    test "3: an ordinary tree is read as before, pages listed twice included" do
      doc =
        open!(
          pdf([
            {1, "<</Type/Catalog /Pages 2 0 R>>"},
            {2, "<</Type/Pages /Kids [3 0 R 4 0 R 6 0 R] /MediaBox [0 0 20 20]>>"},
            {3, "<</Type/Page /MediaBox [0 0 10 10]>>"},
            {4, "<</Type/Pages /Kids [5 0 R 5 0 R 2 0 R]>>"},
            {5, "<</Type/Page>>"},
            {6, "<</Type/Page /Rotate 90>>"}
          ])
        )

      assert Enum.map(doc.pages, & &1.ref) ==
               [{:ref, 3, 0}, {:ref, 5, 0}, {:ref, 5, 0}, {:ref, 6, 0}]

      assert Enum.map(doc.pages, & &1.width) == [10.0, 20.0, 20.0, 20.0]
      assert Enum.map(doc.pages, & &1.index) == [0, 1, 2, 3]
    end
  end

  describe "predictors" do
    test "4: a TIFF predictor with rows of no bytes leaves the data alone" do
      raw = <<1, 0, 10, 0, 1, 0, 20, 0>>
      data = :zlib.compress(raw)

      for params <- [
            %{"Predictor" => 2, "Columns" => 0},
            %{"Predictor" => 2, "Columns" => 1, "Colors" => 0},
            %{"Predictor" => 2, "Columns" => 1, "BitsPerComponent" => 0},
            %{"Predictor" => 2, "Columns" => -3}
          ] do
        assert bounded(fn -> Filter.decode!(data, "FlateDecode", params) end) == raw
      end

      bytes =
        xref_stream_pdf(
          "/Size 2 /W [1 2 1] /Filter /FlateDecode /DecodeParms <</Predictor 2 /Columns 0>>",
          data
        )

      assert {:ok, _} = bounded(fn -> Document.open(bytes) end)
    end

    test "5: rows are not sized from /Columns, /Colors or /BitsPerComponent alone" do
      for {raw, params} <- [
            {<<0, 1>>, %{"Predictor" => 12, "Columns" => 500_000_000}},
            {<<2, 1>>, %{"Predictor" => 12, "Columns" => 8_000_000}},
            {<<4, 1>>, %{"Predictor" => 12, "Columns" => 1, "Colors" => 30_000_000}},
            {<<4, 1>>, %{"Predictor" => 15, "Columns" => 1, "BitsPerComponent" => 1 <<< 40}},
            {<<3, 1>>, %{"Predictor" => 12, "Columns" => {:ref, 1, 0}}},
            {<<3, 1>>, %{"Predictor" => {:ref, 1, 0}, "Columns" => 1}}
          ] do
        assert bounded(fn -> Filter.decode!(:zlib.compress(raw), "FlateDecode", params) end) ==
                 raw
      end
    end

    test "5: a row is no longer than rows are" do
      row = :binary.copy(<<1>>, 4_000_000)
      params = %{"Predictor" => 12, "Columns" => 1_000_000, "Colors" => 4}

      assert within_heap(100, fn ->
               Filter.predict(<<2, row::binary>>, params) == <<2, row::binary>>
             end)
    end

    test "5: every PNG row filter still decodes what an encoder wrote" do
      :rand.seed(:exsss, {1, 2, 3})

      for bpp <- [1, 3, 4, 8], type <- 0..4 do
        row_len = bpp * 7
        rows = for _ <- 1..5, do: :crypto.strong_rand_bytes(row_len)

        {encoded, _} =
          Enum.map_reduce(rows, :binary.copy(<<0>>, row_len), fn row, prev ->
            {<<type, png_filter(type, row, prev, bpp)::binary>>, row}
          end)

        params = %{"Predictor" => 15, "Columns" => 7, "Colors" => bpp, "BitsPerComponent" => 8}
        data = :zlib.compress(IO.iodata_to_binary(encoded))

        assert Filter.decode!(data, "FlateDecode", params) == IO.iodata_to_binary(rows),
               "filter #{type}, #{bpp} bytes per pixel"
      end
    end

    test "5: the TIFF predictor still decodes" do
      params = %{"Predictor" => 2, "Columns" => 3, "Colors" => 1}
      assert Filter.predict(<<1, 1, 1, 5, 250, 10>>, params) == <<1, 2, 3, 5, 255, 9>>

      params = %{"Predictor" => 2, "Columns" => 2, "Colors" => 1, "BitsPerComponent" => 16}

      assert Filter.predict(<<1::16, 2::16, 65_535::16, 2::16>>, params) ==
               <<1::16, 3::16, 65_535::16, 1::16>>
    end
  end

  # the forward PNG filters (PNG specification, 9.2)
  defp png_filter(type, row, prev, bpp) do
    row = :binary.bin_to_list(row)
    up = :binary.bin_to_list(prev)
    zeros = List.duplicate(0, bpp)
    left = zeros ++ row
    up_left = zeros ++ up

    [row, left, up, up_left]
    |> Enum.zip()
    |> Enum.map(fn {x, a, b, c} ->
      predicted =
        case type do
          0 -> 0
          1 -> a
          2 -> b
          3 -> div(a + b, 2)
          4 -> paeth(a, b, c)
        end

      band(x - predicted, 0xFF)
    end)
    |> :erlang.list_to_binary()
  end

  defp paeth(a, b, c) do
    p = a + b - c
    {pa, pb, pc} = {abs(p - a), abs(p - b), abs(p - c)}

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  describe "decoded size" do
    test "6: an object stream that inflates past the limit is not expanded" do
      # 260 MB of zeros, deflated twice: about 1 kB in the file
      z = :zlib.open()
      :ok = :zlib.deflateInit(z, 1)
      chunk = :binary.copy(<<0>>, 10_000_000)
      once = for i <- 1..26, do: :zlib.deflate(z, chunk, if(i == 26, do: :finish, else: :none))
      :zlib.close(z)
      twice = once |> IO.iodata_to_binary() |> :zlib.compress()
      assert byte_size(twice) < 20_000

      bytes =
        @head <>
          "5 0 obj\n" <>
          stream("/Type/ObjStm /N 1 /First 4 /Filter [/FlateDecode /FlateDecode]", twice) <>
          "\nendobj\ntrailer\n<</Root 1 0 R>>\n%%EOF\n"

      assert {:ok, doc} = bounded(fn -> Document.open(bytes) end)
      assert map_size(doc.objects) == 3
      assert bounded(fn -> Document.stream_data(doc, {:ref, 5, 0}) end) == ""
    end

    test "6: every filter stops at the limit" do
      limit = 1_000_000
      flate = :zlib.compress(:binary.copy(<<0>>, 5_000_000))
      assert Filter.decode_within(flate, "FlateDecode", nil, limit) == :too_large
      assert {:ok, {out, nil}} = Filter.decode_within(flate, "FlateDecode", nil, 5_000_000)
      assert byte_size(out) == 5_000_000

      # raw deflate, which is tried when the zlib header is wrong
      <<_header::16, raw::binary>> = flate
      assert Filter.decode_within(raw, "Fl", nil, limit) == :too_large

      # each byte of a run-length layer becomes 128
      layer = fn data -> for <<b <- data>>, into: <<>>, do: <<129, b>> end
      three = <<0>> |> layer.() |> layer.() |> layer.()
      four = layer.(three)
      assert byte_size(four) == 16

      assert bounded(fn -> Filter.decode_within(four, ~w(RL RL RL RL), nil, limit) end) ==
               :too_large

      assert Filter.decode_within(three, ~w(RL RL RL), nil, limit) == :too_large
      assert {:ok, {out, nil}} = Filter.decode_within(three, ~w(RL RL RL), nil, 3_000_000)
      assert byte_size(out) > limit and :binary.last(out) == 0

      ascii85 = String.duplicate("z", 400_000)
      assert Filter.decode_within(ascii85, "ASCII85Decode", nil, limit) == :too_large

      hex = String.duplicate("00", 1_200_000)
      assert Filter.decode_within(hex, "AHx", nil, limit) == :too_large

      lzw = lzw_bomb(3_800)
      assert byte_size(lzw) < 6_000
      assert bounded(fn -> Filter.decode_within(lzw, "LZWDecode", nil, limit) end) == :too_large
      assert {:ok, {out, nil}} = Filter.decode_within(lzw, "LZW", nil, 10_000_000)
      assert out == :binary.copy("a", byte_size(out)) and byte_size(out) > 7_000_000
    end

    test "6: over the limit a stream decodes to nothing, and the chain has an end" do
      limit = Filter.max_bytes()
      assert limit == 256_000_000

      assert Filter.decode("x", List.duplicate("ASCIIHexDecode", 9), nil) == {"", nil}
      assert Filter.decode!("3c7e7a7a7e3e>", ~w(AHx A85), nil) == <<0::64>>
      assert Filter.decode("ff", ~w(AHx DCTDecode), nil) == {<<255>>, {"DCTDecode", %{}}}
    end

    test "6: the filters still decode what they decoded" do
      assert Filter.decode!("87cURD]i,\"Ebo80~>", "ASCII85Decode", nil) == "Hello World!"
      assert Filter.decode!("<~87cURD]i,\"Ebo8~>", "A85", nil) == "Hello World"
      assert Filter.decode!("87cUR D]i,\n\"Ebo80", "A85", nil) == "Hello World!"
      assert Filter.decode!("87czURD]i,\"Ebo80", "A85", nil) == "Hello World!"
      assert Filter.decode!("87cURzD]i,\"Ebo80", "A85", nil) == "Hell\0\0\0\0o World!"
      assert Filter.decode!("z!!~>", "A85", nil) == <<0, 0, 0, 0, 0>>
      assert Filter.decode!(<<2, ?a, ?b, ?c, 254, ?z, 128, 9>>, "RL", nil) == "abczzz"
      assert Filter.decode!(<<5, ?a>>, "RL", nil) == "a"
      assert Filter.decode!(<<200>>, "RL", nil) == ""

      # -----A---B (ISO 32000-1, 7.4.4.2)
      lzw = <<0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01>>
      assert Filter.decode!(lzw, "LZWDecode", nil) == <<45, 45, 45, 45, 45, 65, 45, 45, 45, 66>>

      # codes that name nothing used to raise
      assert is_binary(Filter.decode!(<<300::9, 301::9, 302::9, 0::5>>, "LZWDecode", nil))
      assert is_binary(Filter.decode!(<<97::9, 300::9, 0::6>>, "LZW", %{"EarlyChange" => "x"}))

      assert Filter.inflate(:zlib.compress("abc")) == "abc"
      assert Filter.inflate("not deflate at all") == ""
    end
  end

  # `a`, then codes that each name the string one byte longer than the last
  defp lzw_bomb(count) do
    {bits, _} =
      Enum.reduce(0..(count - 1), {<<>>, 258}, fn i, {acc, next} ->
        width =
          cond do
            next + 1 >= 2048 -> 12
            next + 1 >= 1024 -> 11
            next + 1 >= 512 -> 10
            true -> 9
          end

        code = if i == 0, do: 97, else: 257 + i
        next = if i == 0, do: next, else: min(next + 1, 4096)
        {<<acc::bitstring, code::size(width)>>, next}
      end)

    pad = rem(8 - rem(bit_size(bits), 8), 8)
    <<bits::bitstring, 0::size(pad)>>
  end

  describe "parser" do
    test "7: a long run of digits is one number, read in one pass" do
      digits = String.duplicate("9", 400_000)

      assert {n, " x"} = bounded(fn -> Parser.parse_number(digits <> " x") end)
      assert n == 99_999_999_999_999_999_999
      assert {m, ""} = bounded(fn -> Parser.parse_number("-" <> digits) end)
      assert m == -n

      # the slow path, taken by odd forms such as a doubled sign
      assert bounded(fn -> Parser.parse_number("--" <> digits) end) == {n, ""}

      assert {:ok, _} =
               bounded(fn ->
                 Document.open(
                   "%PDF-1.7\n1 0 obj\n<</Type/Catalog /Pages 2 0 R /X #{digits}>>\nendobj\n" <>
                     "2 0 obj\n<</Type/Pages /Kids [] /Count 0>>\nendobj\ntrailer\n<</Root 1 0 R>>\n"
                 )
               end)
    end

    test "7: numbers within the limits are read as before" do
      assert Parser.parse_number("18446744073709551615") == {18_446_744_073_709_551_615, ""}
      assert Parser.parse_number("99999999999999999999 ") == {99_999_999_999_999_999_999, " "}
      assert Parser.parse_number("0000000000000000000000000017 0") == {17, " 0"}
      assert Parser.parse_number("-12.5]") == {-12.5, "]"}
      assert Parser.parse_number("0.1234567890123456789") == {0.12345678901234568, ""}
      assert Parser.parse_number("--5") == {5, ""}
      assert Parser.parse_number("1.2.3") == {1.23, ""}
      assert Parser.to_number("00012") == 12
    end

    test "32: a real with hundreds of digits is a float, not an exception" do
      ones = String.duplicate("1", 400)
      nines = String.duplicate("9", 400)

      assert {x, ""} = Parser.parse_number("0." <> ones)
      assert_in_delta x, 0.1111111, 1.0e-6
      assert {y, ""} = Parser.parse_number(nines <> ".5")
      assert y == 1.0e20
      assert {z, ""} = Parser.parse_number("-" <> nines <> "." <> ones)
      assert z == -1.0e20

      assert [{"m", [^x, 0]}] = Content.parse("0." <> ones <> " 0 m")
      assert [{"m", [^y, 0]}, {"l", [1, 1]}, {"S", []}] = Content.parse(nines <> ".5 0 m 1 1 l S")

      # an inline image whose bit depth is no number has no known length
      assert [{"BI", [%{data: <<1, 2>>}]}] = Content.parse("BI /W 2 /H 1 /BPC /x ID \x01\x02 EI")
    end

    test "8: streams without endstream do not each scan to the end of the file" do
      streams = for i <- 3..40_002, into: "", do: "#{i} 0 obj<<>>stream\n"
      bytes = @head <> streams <> "trailer\n<</Root 1 0 R>>\n"

      # what is left of the file once the budget is spent is not loaded
      assert returns?(bytes)

      # the same through an indirect /Length that is itself such a stream
      streams = for i <- 4..20_003, into: "", do: "#{i} 0 obj<</Length 3 0 R>>stream\n"
      bytes = @head <> "3 0 obj<<>>stream\n" <> streams <> "trailer\n<</Root 1 0 R>>\n"
      assert returns?(bytes)
    end

    test "8: objects that contain each other are not each parsed to the end" do
      arrays = for i <- 3..20_002, into: "", do: "#{i} 0 obj [ "
      bytes = @head <> arrays <> "trailer\n<</Root 1 0 R>>\n"
      assert returns?(bytes)

      dicts = for i <- 3..10_002, into: "", do: "#{i} 0 obj<</A 1 endobj\n"
      bytes = @head <> dicts <> "trailer\n<</Root 1 0 R>>\n"
      assert {:ok, doc} = bounded(fn -> Document.open(bytes) end)
      assert map_size(doc.objects) == 10_002
      assert doc.objects[10_002] == %{"A" => 1}
    end

    test "8: the objects of an object stream that contain each other share a budget" do
      count = 50_000
      header = for i <- 1..count, into: "", do: "#{i + 10} #{rem(i, 400)} "
      body = String.duplicate("(", 400) <> String.duplicate("x", 100_000)

      object_stream =
        stream(
          "/Type/ObjStm /N #{count} /First #{byte_size(header)} /Filter /FlateDecode",
          :zlib.compress(header <> body)
        )

      bytes = @head <> "5 0 obj\n" <> object_stream <> "\nendobj\ntrailer\n<</Root 1 0 R>>\n"
      assert {:ok, doc} = bounded(fn -> Document.open(bytes) end)
      assert map_size(doc.objects) < 100
    end

    test "8: a stream is still found by /Length, by endstream, or to the end of the file" do
      assert {:ok, 4, 0, %{raw: "abc"}} =
               Parser.parse_indirect("4 0 obj<</Length 3>>stream\nabc\nendstream endobj")

      assert {:ok, 4, 0, %{raw: "abcd"}} =
               Parser.parse_indirect("4 0 obj<</Length 99>>stream\nabcd\r\nendstream")

      assert {:ok, 4, 0, %{raw: "abcd"}} =
               Parser.parse_indirect("4 0 obj<</Length 2>>stream\nabcd\nendstream")

      assert {:ok, 4, 0, %{raw: "abcd e"}} = Parser.parse_indirect("4 0 obj<<>>stream\r\nabcd e")
      assert {:ok, 4, 0, %{"A" => 1}} = Parser.parse_indirect("4 0 obj<</A 1 endobj")
      assert Parser.parse_indirect("x 4 0 obj") == :error

      assert {{:ok, 4, 0, 7}, 9} = Parser.parse_indirect_consumed("4 0 obj 7\nendobj")

      assert {{:ok, 4, 0, [1]}, budget} =
               Parser.parse_indirect_within("4 0 obj [1] endobj", fn _ -> nil end, 100)

      assert budget < 100 and budget > 80
      assert Parser.parse_indirect_within("4 0 obj [1] endobj", fn _ -> nil end, 0) == {:error, 0}

      # an indirect /Length is read from the start of its object
      doc =
        open!(
          pdf([
            {1, "<</Type/Catalog /Pages 2 0 R>>"},
            {2, "<</Type/Pages /Kids [] /Count 0>>"},
            {3, "<</Length 4 0 R>>\nstream\nab endstream cd\nendstream"},
            {4, "15"}
          ])
        )

      assert Document.stream_data(doc, {:ref, 3, 0}) == "ab endstream cd"
    end

    test "a token of megabytes costs its size, not a list cell for every byte" do
      long = :binary.copy("a", 8_000_000)

      for {text, expected} <- [
            {long <> " 1", {:keyword, long}},
            {"/" <> long <> " 1", long},
            {"(" <> long <> ") 1", {:string, long}},
            {"<" <> long <> "> 1", {:string, :binary.copy(<<0xAA>>, 4_000_000)}}
          ] do
        assert within_heap(60, fn -> Parser.parse_value(text) == {expected, " 1"} end)
      end

      assert within_heap(60, fn -> Parser.parse_number("+" <> :binary.copy("+-.", 2_000_000)) end) ==
               {0.0, ""}

      assert [{^long, [1]}] = within_heap(60, fn -> Content.parse("1 " <> long) end)
    end

    test "content parsing can stop after so many operations" do
      content = String.duplicate("1 0 0 1 0 0 cm BI /W 1 /H 1 ID x EI q Q ", 1_000)
      assert length(Content.parse(content)) == 4_000
      assert Content.parse(content, max_ops: :infinity) == Content.parse(content)

      assert [{"cm", [1, 0, 0, 1, 0, 0]}, {"BI", [_]}, {"q", []}] =
               Content.parse(content, max_ops: 3)

      assert Content.parse(content, max_ops: 0) == []
    end

    test "9: arrays and dictionaries are followed 500 deep and no further" do
      for {open, close} <- [{"[", "]"}, {"<<", ">>"}, {"<</A [", "]>>"}] do
        deep = String.duplicate(open, 300_000)
        assert {value, _rest} = bounded(fn -> Parser.parse_value(deep <> " 1 " <> close) end)
        assert depth(value) <= 500
      end

      bytes =
        "%PDF-1.7\n1 0 obj\n<</Type/Catalog /Pages 2 0 R /X #{String.duplicate("[", 300_000)}>>\n" <>
          "endobj\n2 0 obj\n<</Type/Pages /Kids [] /Count 0>>\nendobj\ntrailer\n<</Root 1 0 R>>\n"

      assert returns?(bytes)

      # what real files nest is read whole
      nested = String.duplicate("[", 400) <> "7" <> String.duplicate("]", 400)
      assert {value, ""} = Parser.parse_value(nested)
      assert depth(value) == 400
      assert List.flatten(value) == [7]
    end
  end

  defp depth([first | _]), do: 1 + depth(first)
  defp depth(%{} = map) when map_size(map) > 0, do: 1 + depth(map |> Map.values() |> hd())
  defp depth([]), do: 1
  defp depth(%{}), do: 1
  defp depth(_), do: 0

  describe "name trees" do
    defp name_tree_dag(levels, leaf) do
      for i <- 0..(levels - 1) do
        if i == levels - 1,
          do: {20 + i, leaf},
          else: {20 + i, "<</Kids [#{21 + i} 0 R #{21 + i} 0 R #{21 + i} 7 R]>>"}
      end
    end

    test "23: a node that many /Kids list is read once" do
      doc =
        open!(
          pdf(
            [
              {1, "<</Type/Catalog /Pages 2 0 R /Names <</Dests 20 0 R>> /PageLabels 20 0 R>>"},
              {2, "<</Type/Pages /Kids [] /Count 0>>"}
            ] ++ name_tree_dag(40, "<</Names [(a) 1] /Nums [0 <</S /D>>]>>")
          )
        )

      assert bounded(fn -> NameTree.entries(doc, {:ref, 20, 0}) end) == [{"a", 1}]

      assert bounded(fn -> NameTree.number_entries(doc, {:ref, 20, 0}) end) == [
               {0, %{"S" => "D"}}
             ]

      assert bounded(fn -> Destinations.named(doc, "zz") end) == nil
      assert bounded(fn -> Destinations.named(doc, "a") end) == 1
      assert bounded(fn -> Metadata.page_labels(doc) end) == []
    end

    test "23: an array of pairs that many nodes share is read once" do
      pairs = for i <- 1..2_000, into: "", do: "(k#{i}) #{i} "
      leaves = for i <- 0..1_999, do: {100 + i, "<</Names 50 0 R>>"}
      kids = for i <- 0..1_999, into: "", do: "#{100 + i} 0 R "

      doc =
        open!(
          pdf(
            [
              {1, "<</Type/Catalog /Pages 2 0 R>>"},
              {2, "<</Type/Pages /Kids [] /Count 0>>"},
              {20, "<</Kids [#{kids}]>>"},
              {50, "[#{pairs}]"}
            ] ++ leaves
          )
        )

      assert length(bounded(fn -> NameTree.entries(doc, {:ref, 20, 0}) end)) == 2_000
    end

    test "23: an ordinary tree is read in order" do
      doc =
        open!(
          pdf([
            {1, "<</Type/Catalog /Pages 2 0 R>>"},
            {2, "<</Type/Pages /Kids [] /Count 0>>"},
            {20, "<</Names [(a) 1] /Kids [21 0 R <</Names [(d) 4 (e)]>> 22 0 R 20 0 R]>>"},
            {21, "<</Kids [23 0 R]>>"},
            {22, "<</Names [(f) 6]>>"},
            {23, "<</Names [(b) 2 /c 3]>>"}
          ])
        )

      assert NameTree.entries(doc, {:ref, 20, 0}) ==
               [{"a", 1}, {"b", 2}, {"c", 3}, {"d", 4}, {"f", 6}]

      assert NameTree.lookup(doc, {:ref, 20, 0}, "d") == 4
    end
  end

  describe "page labels" do
    defp labelled(labels, pages \\ 2) do
      kids = for i <- 1..pages, into: "", do: "#{9 + i} 0 R "
      page_objects = for i <- 1..pages, do: {9 + i, "<</Type/Page /MediaBox [0 0 10 10]>>"}

      open!(
        pdf(
          [
            {1, "<</Type/Catalog /Pages 2 0 R /PageLabels <</Nums [#{labels}]>>>>"},
            {2, "<</Type/Pages /Kids [#{kids}] /Count #{pages}>>"}
          ] ++ page_objects
        )
      )
    end

    test "28: a label is not sized from /St" do
      for style <- ~w(A a R r D) do
        doc = labelled("0 <</S /#{style} /St 13000000000>>")
        labels = bounded(fn -> Metadata.page_labels(doc) end)
        assert length(labels) == 2
        assert Enum.all?(labels, &(byte_size(&1) <= 64)), style
      end

      doc = labelled("0 <</S /D /St (x) /P (#{String.duplicate("é", 100_000)})>>")
      assert [label, _] = bounded(fn -> Metadata.page_labels(doc) end)
      assert String.valid?(label) and byte_size(label) <= 257 and String.ends_with?(label, "1")
    end

    test "28: thousands of ranges over thousands of pages are one pass" do
      ranges = for i <- 0..9_999, into: "", do: "#{i} <</S /D /St #{i * 2 + 1}>> "
      doc = labelled(ranges, 10_000)
      labels = bounded(fn -> Metadata.page_labels(doc) end)
      assert length(labels) == 10_000
      assert Enum.take(labels, 3) == ["1", "3", "5"]
      assert List.last(labels) == "19999"
    end

    test "28: ordinary labels are as before" do
      doc =
        labelled(
          "0 <</S /r>> 4 <</S /D>> 6 <</S /A /St 26 /P (App-)>> 9 <</P (end)>> 3 <</S /R /St 3999>>",
          10
        )

      assert Metadata.page_labels(doc) ==
               ~w(i ii iii MMMCMXCIX 1 2 App-Z App-AA App-BB end)

      assert Metadata.page_labels(labelled("2 <</S /a /St 1663>>", 5)) ==
               [
                 "1",
                 "2",
                 String.duplicate("y", 64),
                 String.duplicate("z", 64),
                 String.duplicate("a", 64)
               ]
    end
  end

  describe "appearance strings" do
    test "30: a /DA of a megabyte of digits is not matched against whole" do
      digits = String.duplicate("1", 1_000_000)

      doc =
        open!(
          pdf([
            {1, "<</Type/Catalog /Pages 2 0 R /AcroForm <</Fields [5 0 R]>>>>"},
            {2, "<</Type/Pages /Kids [3 0 R] /Count 1>>"},
            {3, "<</Type/Page /MediaBox [0 0 100 100] /Annots [5 0 R 6 0 R]>>"},
            {5,
             "<</Type/Annot /Subtype/Widget /FT/Tx /T (a) /Rect [0 0 50 20] /DA (#{digits})>>"},
            {6,
             "<</Type/Annot /Subtype/FreeText /Rect [0 0 50 20] /Contents (x) /DA (#{digits})>>"}
          ])
        )

      assert [%{name: "a"}] = bounded(fn -> Forms.fields(doc) end)
      assert %Document{} = bounded(fn -> Forms.set_value(doc, "a", "hello") end)

      dict = Document.resolve(doc, {:ref, 6, 0})

      assert %EmbedPdf.Annotation{} =
               bounded(fn -> EmbedPdf.Annotation.from_dict(doc, 6, dict, 0) end)
    end

    test "30: an ordinary /DA is read as before" do
      dict = %{
        "Subtype" => "FreeText",
        "Rect" => [0, 0, 50, 20],
        "DA" => {:string, "/Cour 9.5 Tf 1 0 0.5 rg"}
      }

      annotation = EmbedPdf.Annotation.from_dict(%Document{}, 6, dict, 0)
      assert annotation.font_size == 9.5
      assert annotation.font_color == {1.0, 0.0, 0.5}
      assert annotation.font_family == :courier
    end
  end

  describe "outline" do
    test "31: named destinations are looked up once for the whole outline" do
      count = 4_000
      names = for i <- 1..count, into: "", do: "(n#{i}) [3 0 R /FitH #{i}] "

      items =
        for i <- 1..count do
          next = if i < count, do: "/Next #{100 + i} 0 R", else: ""
          {99 + i, "<</Title (t#{i}) /Parent 10 0 R /Dest (n#{count + 1 - i}) #{next}>>"}
        end

      doc =
        open!(
          pdf(
            [
              {1,
               "<</Type/Catalog /Pages 2 0 R /Outlines 10 0 R /Names <</Dests <</Names [#{names}]>>>>>>"},
              {2, "<</Type/Pages /Kids [3 0 R] /Count 1>>"},
              {3, "<</Type/Page /MediaBox [0 0 100 100]>>"},
              {10, "<</Type/Outlines /First 100 0 R /Count #{count}>>"}
            ] ++ items
          )
        )

      {micros, tree} = :timer.tc(fn -> bounded(fn -> Outline.tree(doc) end) end)
      assert length(tree) == count
      assert micros < 1_000_000

      assert %{title: "t1", dest: %{page: 0, fit: :fit_h, top: 4000.0}} = hd(tree)
      assert %{title: "t4000", dest: %{top: 1.0}} = List.last(tree)
    end

    test "31: destinations resolve the same with and without the lookup" do
      doc =
        open!(
          pdf([
            {1,
             "<</Type/Catalog /Pages 2 0 R /Dests <</old [4 0 R /XYZ 1 2 0]>> " <>
               "/Names <</Dests <</Names [(a) [3 0 R /Fit] (a) [4 0 R /Fit] (b) <</D [4 0 R /FitV 5]>> (old) [3 0 R] (c) (b)]>>>>>>"},
            {2, "<</Type/Pages /Kids [3 0 R 4 0 R] /Count 2>>"},
            {3, "<</Type/Page /MediaBox [0 0 100 100]>>"},
            {4, "<</Type/Page /MediaBox [0 0 100 100]>>"}
          ])
        )

      ctx = Destinations.context(doc)

      for dest <- [
            {:string, "a"},
            {:string, "b"},
            {:string, "c"},
            {:string, "old"},
            "old",
            {:string, "none"},
            [{:ref, 4, 0}, "FitH", 7],
            [{:ref, 99, 0}, "Fit"],
            [1, "Fit"],
            [2, "Fit"],
            {:ref, 3, 0},
            7
          ] do
        assert Destinations.resolve(doc, dest, ctx) == Destinations.resolve(doc, dest),
               inspect(dest)
      end

      assert %{page: 0} = Destinations.resolve(doc, {:string, "a"}, ctx)
      assert %{page: 1, fit: :fit_v} = Destinations.resolve(doc, {:string, "c"}, ctx)
      assert %{page: 1, fit: :xyz} = Destinations.resolve(doc, {:string, "old"}, ctx)

      item = %{"A" => %{"S" => "GoTo", "D" => {:string, "b"}}}
      assert Destinations.of_item(doc, item, ctx) == Destinations.of_item(doc, item)
      assert {:goto, %{page: 1}} = Destinations.of_item(doc, item, ctx)
    end
  end
end
