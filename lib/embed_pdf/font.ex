defmodule EmbedPdf.Font do
  @moduledoc """
  A loaded PDF font: how its strings split into glyphs, each glyph's width
  and Unicode text, and (through `EmbedPdf.Font.Program`) its outline.

  Widths are in text-space units for a font size of 1 (a 500/1000 glyph is
  `0.5`), already through `/FontMatrix` for Type 3 fonts.
  """

  alias EmbedPdf.PDF.{Document, Stream}
  alias EmbedPdf.Font.{AFM, CMap, Encoding, GlyphList, Program}

  defstruct type: "Type1",
            base_font: nil,
            cid_type: nil,
            # simple fonts: %{code => glyph name}; Type 0: %CMap{}
            encoding: %{},
            differences?: false,
            to_unicode: nil,
            ucs2: nil,
            widths: %{},
            default_width: 0.0,
            vertical?: false,
            font_matrix: [0.001, 0.0, 0.0, 0.001, 0.0, 0.0],
            ascent: 0.8,
            descent: -0.2,
            flags: 0,
            standard: nil,
            symbolic?: false,
            program: nil,
            cid_to_gid: :identity,
            type3: nil,
            id: nil

  @type t :: %__MODULE__{}

  @typedoc """
  A decoded glyph: `{code, cid_or_code, unicode, width, n_bytes}`.
  `width` is the horizontal advance for size 1; word spacing applies when
  `code == 32` and `n_bytes == 1`.
  """
  @type glyph :: {non_neg_integer(), non_neg_integer(), String.t(), float(), pos_integer()}

  @doc "Loads a font from its dictionary (or a reference to it)."
  @spec load(Document.t(), term()) :: t()
  def load(doc, ref_or_dict) do
    dict = Document.resolve(doc, ref_or_dict)
    id = with {:ref, n, _} <- ref_or_dict, do: n

    font =
      if is_map(dict) do
        case Document.resolve(doc, dict["Subtype"]) do
          "Type0" -> load_type0(doc, dict)
          "Type3" -> load_type3(doc, dict)
          subtype -> load_simple(doc, dict, subtype || "Type1")
        end
      else
        load_simple(doc, %{"BaseFont" => "Helvetica"}, "Type1")
      end

    %{font | id: id}
  rescue
    _ -> %{load_simple(doc, %{"BaseFont" => "Helvetica"}, "Type1") | id: nil}
  end

  # ---------------------------------------------------------------- simple fonts

  defp load_simple(doc, dict, subtype) do
    base = Document.resolve(doc, dict["BaseFont"])
    descriptor = Document.resolve(doc, dict["FontDescriptor"]) || %{}
    flags = Document.resolve(doc, descriptor["Flags"]) || 0
    symbolic? = Bitwise.band(flags, 4) != 0 and Bitwise.band(flags, 32) == 0
    standard = AFM.standard_name(base)
    embedded? = Enum.any?(~w(FontFile FontFile2 FontFile3), &Map.has_key?(descriptor, &1))
    program = Program.load(doc, descriptor, subtype)

    {encoding, differences?} = simple_encoding(doc, dict, standard, program, symbolic?, embedded?)
    afm = AFM.get(standard)

    widths = simple_widths(doc, dict, encoding, afm)

    missing =
      case Document.resolve(doc, descriptor["MissingWidth"]) do
        w when is_number(w) and w > 0 -> w / 1000
        _ -> 0.0
      end

    %__MODULE__{
      type: subtype,
      base_font: base,
      encoding: encoding,
      differences?: differences?,
      to_unicode: load_to_unicode(doc, dict),
      widths: widths,
      default_width: missing,
      ascent: descriptor_metric(doc, descriptor, "Ascent", afm && afm.ascent, 0.8),
      descent: descriptor_metric(doc, descriptor, "Descent", afm && afm.descent, -0.2),
      flags: flags,
      standard: if(embedded?, do: nil, else: standard),
      symbolic?: symbolic? or standard in ["Symbol", "ZapfDingbats"],
      program: program
    }
    |> program_widths()
  end

  # a font dictionary without /Widths (and without standard metrics) takes
  # its advances from the embedded program
  defp program_widths(%__MODULE__{widths: w, program: program} = font)
       when map_size(w) == 0 and program != nil do
    widths =
      for code <- 0..255,
          width = Program.advance(program, font, code),
          is_number(width) and width > 0,
          into: %{},
          do: {code, width}

    %{font | widths: widths}
  rescue
    _ -> font
  end

  defp program_widths(font), do: font

  defp descriptor_metric(doc, descriptor, key, afm_value, default) do
    case Document.resolve(doc, descriptor[key]) do
      v when is_number(v) and v != 0 -> v / 1000
      _ -> if afm_value, do: afm_value / 1000, else: default
    end
  end

  defp simple_encoding(doc, dict, standard, program, symbolic?, embedded?) do
    enc = Document.resolve(doc, dict["Encoding"])

    builtin =
      cond do
        program && Program.builtin_encoding(program) -> Program.builtin_encoding(program)
        standard in ["Symbol", "ZapfDingbats"] -> Encoding.builtin(standard)
        symbolic? and embedded? -> %{}
        true -> Encoding.named("StandardEncoding")
      end

    case enc do
      name when is_binary(name) ->
        {Encoding.named(name) || builtin, false}

      %{} = e ->
        base_name = Document.resolve(doc, e["BaseEncoding"])

        base =
          cond do
            is_binary(base_name) and Encoding.named(base_name) -> Encoding.named(base_name)
            # a non-symbolic font without base encoding uses StandardEncoding
            true -> builtin
          end

        diffs = Document.resolve(doc, e["Differences"])
        {Encoding.apply_differences(base, diffs), is_list(diffs)}

      _ ->
        {builtin, false}
    end
  end

  defp simple_widths(doc, dict, encoding, afm) do
    first = Document.resolve(doc, dict["FirstChar"])

    case Document.resolve(doc, dict["Widths"]) do
      list when is_list(list) and is_integer(first) ->
        list
        |> Enum.with_index(first)
        |> Map.new(fn {w, code} ->
          w = Document.resolve(doc, w)
          {code, if(is_number(w), do: w / 1000, else: 0.0)}
        end)

      _ when afm != nil ->
        Map.new(encoding, fn {code, name} -> {code, Map.get(afm.widths, name, 0) / 1000} end)

      _ ->
        %{}
    end
  end

  # ---------------------------------------------------------------- Type 3

  defp load_type3(doc, dict) do
    matrix =
      case Document.resolve(doc, dict["FontMatrix"]) do
        [_, _, _, _, _, _] = m -> Enum.map(m, &((Document.resolve(doc, &1) || 0) / 1))
        _ -> [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]
      end

    {encoding, diffs?} =
      case Document.resolve(doc, dict["Encoding"]) do
        %{} = e ->
          {Encoding.apply_differences(%{}, Document.resolve(doc, e["Differences"])), true}

        _ ->
          {%{}, false}
      end

    first = Document.resolve(doc, dict["FirstChar"]) || 0
    [a | _] = matrix

    widths =
      case Document.resolve(doc, dict["Widths"]) do
        list when is_list(list) ->
          list
          |> Enum.with_index(first)
          |> Map.new(fn {w, code} ->
            w = Document.resolve(doc, w)
            {code, if(is_number(w), do: w * a, else: 0.0)}
          end)

        _ ->
          %{}
      end

    %__MODULE__{
      type: "Type3",
      base_font: Document.resolve(doc, dict["Name"]),
      encoding: encoding,
      differences?: diffs?,
      to_unicode: load_to_unicode(doc, dict),
      widths: widths,
      font_matrix: matrix,
      type3: %{
        char_procs: Document.resolve(doc, dict["CharProcs"]) || %{},
        resources: Document.resolve(doc, dict["Resources"])
      }
    }
  end

  # ---------------------------------------------------------------- Type 0

  defp load_type0(doc, dict) do
    descendant =
      case Document.resolve(doc, dict["DescendantFonts"]) do
        [d | _] -> Document.resolve(doc, d)
        d when is_map(d) -> d
        _ -> %{}
      end

    descriptor = Document.resolve(doc, descendant["FontDescriptor"]) || %{}
    cid_type = Document.resolve(doc, descendant["Subtype"])

    cmap =
      case Document.resolve(doc, dict["Encoding"]) do
        name when is_binary(name) -> CMap.predefined(name) || CMap.identity()
        %Stream{} = s -> CMap.parse(Document.stream_data(doc, s) || "")
        _ -> CMap.identity()
      end

    ucs2 =
      case Document.resolve(doc, descendant["CIDSystemInfo"]) do
        %{"Registry" => {:string, "Adobe"}, "Ordering" => {:string, ord}}
        when ord in ~w(Japan1 GB1 CNS1 Korea1) ->
          {:ucs2, ord}

        _ ->
          nil
      end

    dw =
      case Document.resolve(doc, descendant["DW"]) do
        w when is_number(w) -> w / 1000
        _ -> 1.0
      end

    cid_to_gid =
      case Document.resolve(doc, descendant["CIDToGIDMap"]) do
        %Stream{} = s -> Document.stream_data(doc, s)
        _ -> :identity
      end

    program_type = if cid_type == "CIDFontType2", do: "TrueType", else: "CIDFontType0"
    flags = Document.resolve(doc, descriptor["Flags"]) || 0

    %__MODULE__{
      type: "Type0",
      cid_type: cid_type,
      base_font: Document.resolve(doc, dict["BaseFont"]),
      encoding: cmap,
      to_unicode: load_to_unicode(doc, dict),
      ucs2: ucs2,
      widths: cid_widths(doc, Document.resolve(doc, descendant["W"])),
      default_width: dw,
      vertical?: cmap.wmode == 1,
      ascent: descriptor_metric(doc, descriptor, "Ascent", nil, 0.88),
      descent: descriptor_metric(doc, descriptor, "Descent", nil, -0.12),
      flags: flags,
      program: Program.load(doc, descriptor, program_type),
      cid_to_gid: cid_to_gid,
      standard:
        if(Enum.any?(~w(FontFile FontFile2 FontFile3), &Map.has_key?(descriptor, &1)),
          do: nil,
          else: AFM.standard_name(Document.resolve(doc, dict["BaseFont"]))
        )
    }
  end

  defp cid_widths(doc, list) when is_list(list),
    do: cid_w(Enum.map(list, &Document.resolve(doc, &1)), doc, %{})

  defp cid_widths(_, _), do: %{}

  defp cid_w([first, ws | rest], doc, acc) when is_integer(first) and is_list(ws) do
    acc =
      ws
      |> Enum.with_index(first)
      |> Enum.reduce(acc, fn {w, cid}, acc ->
        w = Document.resolve(doc, w)
        if is_number(w), do: Map.put(acc, cid, w / 1000), else: acc
      end)

    cid_w(rest, doc, acc)
  end

  defp cid_w([first, last, w | rest], doc, acc)
       when is_integer(first) and is_integer(last) and is_number(w) do
    # very large ranges are kept compact as a range entry
    acc =
      if last - first > 5000,
        do: Map.update(acc, :ranges, [{first, last, w / 1000}], &[{first, last, w / 1000} | &1]),
        else: Enum.reduce(first..last//1, acc, &Map.put(&2, &1, w / 1000))

    cid_w(rest, doc, acc)
  end

  defp cid_w(_, _doc, acc), do: acc

  defp load_to_unicode(doc, dict) do
    case Document.resolve(doc, dict["ToUnicode"]) do
      %Stream{} = s ->
        case Document.stream_data(doc, s) do
          data when is_binary(data) -> CMap.parse(data)
          _ -> nil
        end

      name when is_binary(name) ->
        CMap.predefined(name)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------- decoding

  @doc "Splits a string shown with this font into glyphs."
  @spec decode(t(), binary()) :: [glyph()]
  def decode(%__MODULE__{type: "Type0", encoding: cmap} = font, bytes) do
    cmap
    |> CMap.codes(bytes)
    |> Enum.map(fn {code, n} ->
      cid = CMap.cid(cmap, code, n)
      {code, cid, unicode_cid(font, code, n, cid), cid_width(font, cid), n}
    end)
  end

  def decode(font, bytes) do
    for <<code <- bytes>> do
      {code, code, unicode_simple(font, code), Map.get(font.widths, code, font.default_width), 1}
    end
  end

  defp cid_width(font, cid) do
    case Map.fetch(font.widths, cid) do
      {:ok, w} ->
        w

      :error ->
        case Map.get(font.widths, :ranges) do
          nil ->
            font.default_width

          ranges ->
            Enum.find_value(ranges, font.default_width, fn {a, b, w} ->
              if cid >= a and cid <= b, do: w
            end)
        end
    end
  end

  defp unicode_cid(font, code, n, cid) do
    from_to_unicode =
      case font.to_unicode do
        nil -> nil
        tu -> CMap.unicode(tu, code, n)
      end

    from_to_unicode ||
      case font.ucs2 do
        {:ucs2, ord} ->
          case CMap.predefined("Adobe-" <> ord <> "-UCS2") do
            nil -> nil
            cm -> CMap.unicode(cm, cid, 2)
          end

        nil ->
          nil
      end ||
      (font.program &&
         Program.unicode_for_gid(
           font.program,
           Program.glyph_id(font.program, font, {code, cid, "", 0.0, n}) || gid(font, cid)
         )) ||
      ""
  end

  defp unicode_simple(font, code) do
    from_tu =
      case font.to_unicode do
        nil -> nil
        tu -> CMap.unicode(tu, code, 1)
      end

    from_tu ||
      glyph_name_unicode(font, Map.get(font.encoding, code)) ||
      (font.program && Program.unicode_for_code(font.program, code)) ||
      fallback_code(font, code)
  end

  defp glyph_name_unicode(_font, nil), do: nil

  defp glyph_name_unicode(font, name) do
    GlyphList.to_unicode(name, font.standard == "ZapfDingbats") ||
      case Regex.run(~r/^(?:g|G|cid|c)(\d{2,5})$/, name) do
        # names such as "g37" or "c65" carry no meaning, except "cNN" as char codes
        [_, digits] ->
          if String.starts_with?(name, "c") and not String.starts_with?(name, "cid"),
            do: code_text(String.to_integer(digits)),
            else: nil

        _ ->
          nil
      end
  end

  defp code_text(n) when n >= 32 and n < 0xD800, do: <<n::utf8>>
  defp code_text(_), do: nil

  defp fallback_code(font, code) do
    cond do
      font.symbolic? and code >= 0xF020 -> nil
      code >= 32 and code < 127 -> <<code>>
      code >= 160 -> <<code::utf8>>
      true -> ""
    end
  end

  @doc "Glyph id for a CID (CIDFontType2 with a CIDToGIDMap)."
  @spec gid(t(), non_neg_integer()) :: non_neg_integer()
  def gid(%__MODULE__{cid_to_gid: :identity}, cid), do: cid

  def gid(%__MODULE__{cid_to_gid: map}, cid) when is_binary(map) do
    if 2 * cid + 1 < byte_size(map),
      do: :binary.decode_unsigned(binary_part(map, 2 * cid, 2)),
      else: cid
  end

  @doc "Glyph name of a simple-font code."
  def glyph_name(%__MODULE__{encoding: enc}, code) when is_map(enc) and not is_struct(enc),
    do: Map.get(enc, code)

  def glyph_name(_, _), do: nil

  @doc """
  The outline of a glyph as path commands in text space for size 1
  (`{:move, x, y}`, `{:line, x, y}`, `{:curve, x1, y1, x2, y2, x, y}`,
  `:close`), or nil when the font has no usable program for it.
  """
  @spec glyph_outline(t(), glyph()) :: list() | nil
  def glyph_outline(%__MODULE__{program: nil}, _glyph), do: nil
  def glyph_outline(%__MODULE__{type: "Type3"}, _glyph), do: nil
  def glyph_outline(font, glyph), do: Program.outline(font.program, font, glyph)

  @doc "The Type 3 glyph procedure for a code: `{stream, resources}` or nil."
  @spec type3_proc(t(), non_neg_integer()) :: {term(), map() | nil} | nil
  def type3_proc(%__MODULE__{type3: %{char_procs: procs, resources: res}} = font, code) do
    case Map.get(font.encoding, code) do
      nil -> nil
      name -> if p = Map.get(procs, name), do: {p, res}, else: nil
    end
  end

  def type3_proc(_, _), do: nil

  @doc "CSS font settings to draw this font's text with system fonts."
  @spec css(t()) :: %{family: String.t(), weight: String.t(), style: String.t()}
  def css(font) do
    name = (font.base_font || "") |> AFM.strip_subset()
    lower = String.downcase(name)

    serif? =
      Bitwise.band(font.flags, 2) != 0 or
        String.contains?(
          lower,
          ~w(times roman serif georgia garamond minion cambria book palatino)
        )

    mono? = Bitwise.band(font.flags, 1) != 0 or String.contains?(lower, ~w(courier mono consol))

    family =
      cond do
        font.standard == "Symbol" -> "Symbol, 'Times New Roman', serif"
        font.standard == "ZapfDingbats" -> "'Zapf Dingbats', 'Segoe UI Symbol', sans-serif"
        mono? -> "'Courier New', Courier, monospace"
        serif? and not String.contains?(lower, "sans") -> "'Times New Roman', Times, serif"
        true -> "Helvetica, Arial, sans-serif"
      end

    bold? =
      Bitwise.band(font.flags, 0x40000) != 0 or
        String.contains?(lower, ~w(bold black heavy semibold demi))

    italic? = Bitwise.band(font.flags, 64) != 0 or String.contains?(lower, ~w(italic oblique))

    %{
      family: family,
      weight: if(bold?, do: "bold", else: "normal"),
      style: if(italic?, do: "italic", else: "normal")
    }
  end
end
