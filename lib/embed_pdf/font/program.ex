defmodule EmbedPdf.Font.Program do
  @moduledoc """
  Embedded font programs (`FontFile`, `FontFile2`, `FontFile3`) and the
  glyph outlines drawn from them.

  This is the boundary between `EmbedPdf.Font` and the font-format parsers
  (`EmbedPdf.Font.TrueType`, `EmbedPdf.Font.CFF`, `EmbedPdf.Font.Type1`).
  The program format is sniffed from the bytes, since PDFs often label it
  wrongly. Every function returns nil when it cannot help, and callers fall
  back. Parsed programs are memoized by content hash.

  Glyph selection follows what pdf.js and PDFium do for each font kind.
  """

  alias EmbedPdf.PDF.{Document, Stream}
  alias EmbedPdf.Font.{CFF, Encoding, GlyphList, TrueType, Type1}

  defstruct kind: nil, tt: nil, cff: nil, t1: nil, id: nil

  @type t :: %__MODULE__{kind: :truetype | :opentype_cff | :cff | :type1}

  @table :embed_pdf_font_programs
  @owner :embed_pdf_font_program_cache
  @max_entries 12_000

  @doc "Parses the font program referenced by a font descriptor, or nil."
  @spec load(Document.t(), map(), String.t()) :: t() | nil
  def load(doc, descriptor, _subtype) when is_map(descriptor) do
    stream =
      Enum.find_value(~w(FontFile2 FontFile3 FontFile), fn key ->
        case Document.resolve(doc, descriptor[key]) do
          %Stream{} = s -> s
          _ -> nil
        end
      end)

    case stream do
      nil ->
        nil

      %Stream{raw: raw, dict: dict} ->
        key = {:crypto.hash(:md5, raw), byte_size(raw), :erlang.phash2(dict["Filter"])}

        memo(key, fn ->
          case Document.stream_data(doc, stream) do
            bytes when is_binary(bytes) and byte_size(bytes) > 4 ->
              case parse(bytes) do
                %__MODULE__{} = p -> %{p | id: :erlang.phash2(key)}
                nil -> nil
              end

            _ ->
              nil
          end
        end)
    end
  rescue
    _ -> nil
  end

  def load(_doc, _descriptor, _subtype), do: nil

  @doc "Parses font program bytes of any supported format."
  @spec parse(binary()) :: t() | nil
  def parse(bytes) do
    cond do
      TrueType.sfnt?(bytes) ->
        case TrueType.parse(bytes) do
          {:ok, %TrueType{cff: %CFF{} = cff} = tt} ->
            %__MODULE__{kind: :opentype_cff, tt: tt, cff: cff}

          {:ok, tt} ->
            %__MODULE__{kind: :truetype, tt: tt}

          :error ->
            nil
        end

      CFF.cff?(bytes) ->
        case CFF.parse(bytes) do
          {:ok, cff} -> %__MODULE__{kind: :cff, cff: cff}
          :error -> nil
        end

      Type1.type1?(bytes) ->
        case Type1.parse(bytes) do
          {:ok, t1} -> %__MODULE__{kind: :type1, t1: t1}
          :error -> nil
        end

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------- cache

  defp memo(key, fun) do
    table = ensure_table()

    case table && lookup(table, key) do
      {:ok, value} ->
        value

      _ ->
        value = fun.()

        if table do
          try do
            if :ets.info(table, :size) >= @max_entries, do: :ets.delete_all_objects(table)
            :ets.insert(table, {key, value})
          rescue
            _ -> :ok
          end
        end

        value
    end
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{_, value}] -> {:ok, value}
      [] -> :miss
    end
  rescue
    _ -> :miss
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> start_owner()
      _ref -> @table
    end
  end

  # The table needs an owner that outlives render processes.
  defp start_owner do
    parent = self()

    spawn(fn ->
      try do
        Process.register(self(), @owner)
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        send(parent, {@owner, :ready})
        Process.sleep(:infinity)
      rescue
        _ -> send(parent, {@owner, :ready})
      end
    end)

    receive do
      {@owner, :ready} -> :ok
    after
      200 -> :ok
    end

    if :ets.whereis(@table) == :undefined, do: nil, else: @table
  end

  # ---------------------------------------------------------------- encodings / unicode

  @doc "The encoding built into the program (Type 1 / CFF), as `%{code => name}`."
  @spec builtin_encoding(t() | nil) :: map() | nil
  def builtin_encoding(%__MODULE__{kind: :type1, t1: t1}), do: t1.encoding
  def builtin_encoding(%__MODULE__{kind: :cff, cff: cff}), do: CFF.builtin_encoding(cff)
  def builtin_encoding(_), do: nil

  @doc "Unicode text for a glyph id, from the program's own tables."
  @spec unicode_for_gid(t() | nil, non_neg_integer()) :: String.t() | nil
  def unicode_for_gid(%__MODULE__{tt: %TrueType{} = tt} = p, gid) do
    case Map.get(tt.reverse_unicode, gid) do
      cp when is_integer(cp) and cp >= 32 -> <<cp::utf8>>
      _ -> name_unicode(TrueType.glyph_name(tt, gid)) || cff_unicode(p.cff, gid)
    end
  end

  def unicode_for_gid(%__MODULE__{cff: %CFF{} = cff}, gid), do: cff_unicode(cff, gid)
  def unicode_for_gid(_, _), do: nil

  defp cff_unicode(nil, _gid), do: nil
  defp cff_unicode(cff, gid), do: name_unicode(CFF.glyph_name(cff, gid))

  defp name_unicode(nil), do: nil
  defp name_unicode(".notdef"), do: nil
  defp name_unicode(name), do: GlyphList.to_unicode(name)

  @doc "Unicode text for a simple-font code, from the program's own tables."
  @spec unicode_for_code(t() | nil, non_neg_integer()) :: String.t() | nil
  def unicode_for_code(%__MODULE__{tt: %TrueType{} = tt} = p, code) do
    case symbolic_gid(tt, code) do
      nil -> nil
      gid -> unicode_for_gid(p, gid)
    end
  end

  def unicode_for_code(%__MODULE__{kind: :cff, cff: cff}, code) do
    case CFF.code_gid(cff, code) do
      nil -> nil
      gid -> cff_unicode(cff, gid)
    end
  end

  def unicode_for_code(_, _), do: nil

  # ---------------------------------------------------------------- glyph selection

  @doc "The glyph id a decoded glyph selects in the program (nil when none)."
  @spec glyph_id(t() | nil, EmbedPdf.Font.t(), EmbedPdf.Font.glyph()) :: non_neg_integer() | nil
  def glyph_id(nil, _font, _glyph), do: nil

  def glyph_id(%__MODULE__{} = p, %{type: "Type0"} = font, {_code, cid, _uni, _w, _n}) do
    case p.kind do
      :truetype -> EmbedPdf.Font.gid(font, cid)
      :opentype_cff -> cff_cid_gid(p.cff, cid, font)
      :cff -> cff_cid_gid(p.cff, cid, font)
      :type1 -> nil
    end
  end

  def glyph_id(%__MODULE__{kind: :truetype, tt: tt}, font, {code, _cid, _uni, _w, _n}),
    do: truetype_gid(tt, font, code)

  def glyph_id(
        %__MODULE__{kind: :opentype_cff, tt: tt, cff: cff},
        font,
        {code, _cid, _uni, _w, _n}
      ) do
    name = EmbedPdf.Font.glyph_name(font, code)
    (name && CFF.name_gid(cff, name)) || truetype_gid(tt, font, code)
  end

  def glyph_id(%__MODULE__{kind: :cff, cff: cff}, font, {code, _cid, _uni, _w, _n}) do
    if cff.cid? do
      CFF.cid_gid(cff, code)
    else
      name = EmbedPdf.Font.glyph_name(font, code)

      (name && CFF.name_gid(cff, name)) ||
        (name && alternate_name_gid(name, &CFF.name_gid(cff, &1))) ||
        CFF.code_gid(cff, code)
    end
  end

  def glyph_id(_, _, _), do: nil

  defp cff_cid_gid(cff, cid, font) do
    if cff.cid? do
      CFF.cid_gid(cff, cid)
    else
      gid = EmbedPdf.Font.gid(font, cid)
      if gid < cff.num_glyphs, do: gid, else: nil
    end
  end

  # pdf.js-style TrueType simple-font lookup
  defp truetype_gid(tt, font, code) do
    has_encoding? =
      is_map(font.encoding) and not is_struct(font.encoding) and map_size(font.encoding) > 0

    name = if has_encoding?, do: Map.get(font.encoding, code)
    symbolic? = font.symbolic?

    by_name =
      if name && (not symbolic? or font.differences?) do
        name_lookup(tt, name)
      end

    gid =
      by_name ||
        symbolic_gid(tt, code) ||
        (name && name_lookup(tt, name)) ||
        unicode_code_lookup(tt, code, font)

    cond do
      (gid && gid > 0) and gid < max(tt.num_glyphs, 1) -> gid
      (gid && gid > 0) and tt.num_glyphs == 0 -> gid
      map_size(tt.cmaps) == 0 and code < tt.num_glyphs -> code
      true -> nil
    end
  end

  defp name_lookup(tt, name) do
    uni = GlyphList.to_unicode(name)
    cp = uni && match?([_], String.to_charlist(uni)) && hd(String.to_charlist(uni))

    nonzero(cp && TrueType.unicode_lookup(tt, cp)) ||
      nonzero(mac_lookup(tt, name)) ||
      nonzero(TrueType.name_gid(tt, name)) ||
      alternate_name_gid(name, &TrueType.name_gid(tt, &1))
  end

  defp nonzero(0), do: nil
  defp nonzero(v), do: v

  # names such as "uni0041" or "a.alt" with the font naming the base glyph
  defp alternate_name_gid(name, fun) do
    case GlyphList.to_unicode(name) do
      nil ->
        nil

      uni ->
        case GlyphList.to_name(uni) do
          ^name -> nil
          nil -> nil
          other -> fun.(other)
        end
    end
  end

  @mac_codes Encoding.named("MacRomanEncoding") |> Map.new(fn {code, name} -> {name, code} end)

  defp mac_lookup(tt, name) do
    case Map.get(@mac_codes, name) do
      nil -> nil
      code -> TrueType.cmap_lookup(tt, {1, 0}, code)
    end
  end

  @doc false
  # symbolic lookup: (3,0) with the code and the F0xx private area, then (1,0)
  def symbolic_gid(tt, code) do
    Enum.find_value([code, 0xF000 + code, 0xF100 + code, 0xF200 + code], fn c ->
      nonzero(TrueType.cmap_lookup(tt, {3, 0}, c))
    end) || nonzero(TrueType.cmap_lookup(tt, {1, 0}, code))
  end

  # last resort: a Unicode cmap indexed by the raw code (or its Unicode)
  defp unicode_code_lookup(tt, code, font) do
    nonzero(TrueType.unicode_lookup(tt, code)) ||
      case font.to_unicode && EmbedPdf.Font.CMap.unicode(font.to_unicode, code, 1) do
        <<cp::utf8>> -> nonzero(TrueType.unicode_lookup(tt, cp))
        _ -> nil
      end
  end

  # ---------------------------------------------------------------- advances

  @doc """
  The advance width the program gives the glyph of a simple font's `code`,
  in text space for size 1, or nil. Used when the font dictionary has no
  `/Widths`.
  """
  @spec advance(t() | nil, EmbedPdf.Font.t(), 0..255) :: float() | nil
  def advance(%__MODULE__{kind: :type1, t1: t1}, font, code) do
    case EmbedPdf.Font.glyph_name(font, code) || (t1.encoding && Map.get(t1.encoding, code)) do
      nil -> nil
      name -> Type1.advance(t1, name) || alternate_name_glyph(name, &Type1.advance(t1, &1))
    end
  end

  def advance(%__MODULE__{kind: :cff, cff: cff} = p, font, code) do
    gid = glyph_id(p, font, {code, code, nil, 0, 1})
    gid && CFF.advance(cff, gid)
  end

  def advance(%__MODULE__{tt: %TrueType{} = tt} = p, font, code) do
    with gid when is_integer(gid) <- glyph_id(p, font, {code, code, nil, 0, 1}),
         aw when is_integer(aw) <- TrueType.advance(tt, gid) do
      aw / max(tt.units_per_em, 1)
    else
      _ -> nil
    end
  end

  def advance(_, _, _), do: nil

  # ---------------------------------------------------------------- outlines

  @doc "Outline path commands for a decoded glyph (see `EmbedPdf.Font.glyph_outline/2`)."
  @spec outline(t() | nil, EmbedPdf.Font.t(), EmbedPdf.Font.glyph()) :: list() | nil
  def outline(nil, _font, _glyph), do: nil

  def outline(%__MODULE__{kind: :type1, t1: t1} = p, font, {code, _cid, _uni, _w, _n}) do
    case EmbedPdf.Font.glyph_name(font, code) || (t1.encoding && Map.get(t1.encoding, code)) do
      nil ->
        nil

      name ->
        cached_outline(p.id, name, fn ->
          Type1.glyph(t1, name) || alternate_name_glyph(name, &Type1.glyph(t1, &1))
        end)
    end
  end

  def outline(%__MODULE__{kind: :truetype, tt: tt} = p, font, glyph) do
    case glyph_id(p, font, glyph) do
      nil -> nil
      gid -> cached_outline(p.id, gid, fn -> TrueType.glyph(tt, gid) end)
    end
  end

  def outline(%__MODULE__{cff: %CFF{} = cff} = p, font, glyph) do
    case glyph_id(p, font, glyph) do
      nil -> nil
      gid -> cached_outline(p.id, gid, fn -> CFF.glyph(cff, gid) end)
    end
  end

  def outline(_, _, _), do: nil

  # decoded outlines are memoized next to the parsed programs
  defp cached_outline(nil, _sel, fun), do: fun.()
  defp cached_outline(id, sel, fun), do: memo({:outline, id, sel}, fun)

  defp alternate_name_glyph(name, fun) do
    case GlyphList.to_unicode(name) do
      nil ->
        nil

      uni ->
        case GlyphList.to_name(uni) do
          ^name -> nil
          nil -> nil
          other -> fun.(other)
        end
    end
  end
end
