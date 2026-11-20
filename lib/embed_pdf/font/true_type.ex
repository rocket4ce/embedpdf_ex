defmodule EmbedPdf.Font.TrueType do
  @moduledoc """
  TrueType / OpenType (sfnt) fonts: table directory (and the first font of
  a collection), `head`, `maxp`, `loca`/`glyf` outlines (simple and
  composite), `cmap` formats 0, 4, 6, 12 and 13, `hmtx` and `post` names.
  OpenType fonts with CFF outlines (`OTTO`) keep their `CFF ` table parsed
  by `EmbedPdf.Font.CFF`.

  Outlines are returned in font units (see `glyph/2`); `units_per_em`
  scales them to an em.
  """

  import Bitwise

  alias EmbedPdf.Font.{CFF, Outline}

  defstruct tables: %{},
            units_per_em: 1000,
            loca_format: 0,
            num_glyphs: 0,
            loca: <<>>,
            glyf: <<>>,
            cmaps: %{},
            post_names: nil,
            name_to_gid: %{},
            hmtx: <<>>,
            num_hmetrics: 0,
            cff: nil,
            reverse_unicode: %{}

  @type t :: %__MODULE__{}

  @mac_names ~w(.notdef .null nonmarkingreturn space exclam quotedbl numbersign dollar
    percent ampersand quotesingle parenleft parenright asterisk plus comma hyphen period
    slash zero one two three four five six seven eight nine colon semicolon less equal
    greater question at A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft
    backslash bracketright asciicircum underscore grave a b c d e f g h i j k l m n o p q
    r s t u v w x y z braceleft bar braceright asciitilde Adieresis Aring Ccedilla Eacute
    Ntilde Odieresis Udieresis aacute agrave acircumflex adieresis atilde aring ccedilla
    eacute egrave ecircumflex edieresis iacute igrave icircumflex idieresis ntilde oacute
    ograve ocircumflex odieresis otilde uacute ugrave ucircumflex udieresis dagger degree
    cent sterling section bullet paragraph germandbls registered copyright trademark acute
    dieresis notequal AE Oslash infinity plusminus lessequal greaterequal yen mu
    partialdiff summation product pi integral ordfeminine ordmasculine Omega ae oslash
    questiondown exclamdown logicalnot radical florin approxequal Delta guillemotleft
    guillemotright ellipsis nonbreakingspace Agrave Atilde Otilde OE oe endash emdash
    quotedblleft quotedblright quoteleft quoteright divide lozenge ydieresis Ydieresis
    fraction currency guilsinglleft guilsinglright fi fl daggerdbl periodcentered
    quotesinglbase quotedblbase perthousand Acircumflex Ecircumflex Aacute Edieresis Egrave
    Iacute Icircumflex Idieresis Igrave Oacute Ocircumflex apple Ograve Uacute Ucircumflex
    Ugrave dotlessi circumflex tilde macron breve dotaccent ring cedilla hungarumlaut ogonek
    caron Lslash lslash Scaron scaron Zcaron zcaron brokenbar Eth eth Yacute yacute Thorn
    thorn minus multiply onesuperior twosuperior threesuperior onehalf onequarter
    threequarters franc Gbreve gbreve Idotaccent Scedilla scedilla Cacute cacute Ccaron
    ccaron dcroat)

  258 = length(@mac_names)
  @mac_tuple List.to_tuple(@mac_names)

  @doc "The 258 standard Macintosh glyph names (post format 1)."
  def mac_glyph_name(i) when i >= 0 and i < 258, do: elem(@mac_tuple, i)
  def mac_glyph_name(_), do: nil

  @doc "Whether the bytes look like an sfnt font (TrueType, OpenType or a collection)."
  @spec sfnt?(binary()) :: boolean()
  def sfnt?(<<0, 1, 0, 0, _::binary>>), do: true
  def sfnt?(<<"true", _::binary>>), do: true
  def sfnt?(<<"OTTO", _::binary>>), do: true
  def sfnt?(<<"ttcf", _::binary>>), do: true
  def sfnt?(<<"typ1", _::binary>>), do: true
  def sfnt?(_), do: false

  @doc "Parses sfnt bytes."
  @spec parse(binary()) :: {:ok, t()} | :error
  def parse(data) when is_binary(data) do
    with {:ok, offset} <- font_offset(data),
         {:ok, tables} <- directory(data, offset) do
      {:ok, build(tables)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def parse(_), do: :error

  defp font_offset(<<"ttcf", _ver::32, n::32, first::32, _::binary>>) when n > 0, do: {:ok, first}
  defp font_offset(<<"ttcf", _::binary>>), do: :error
  defp font_offset(_), do: {:ok, 0}

  defp directory(data, offset) do
    case data do
      <<_::binary-size(offset), _version::32, num_tables::16, _::binary-6, rest::binary>> ->
        records = read_records(rest, num_tables, [])
        size = byte_size(data)

        tables =
          for {tag, off, len} <- records, off < size, into: %{} do
            {tag, binary_part(data, off, min(len, size - off))}
          end

        if map_size(tables) > 0, do: {:ok, tables}, else: :error

      _ ->
        :error
    end
  end

  defp read_records(_rest, 0, acc), do: Enum.reverse(acc)

  defp read_records(<<tag::binary-4, _sum::32, off::32, len::32, rest::binary>>, n, acc),
    do: read_records(rest, n - 1, [{tag, off, len} | acc])

  defp read_records(_, _, acc), do: Enum.reverse(acc)

  defp build(tables) do
    {upem, loca_format} =
      case tables["head"] do
        <<_::binary-18, upem::16, _::binary-30, fmt::signed-16, _::binary>> ->
          {if(upem in 16..16384, do: upem, else: 1000), fmt}

        _ ->
          {1000, 0}
      end

    loca = Map.get(tables, "loca", <<>>)
    glyf = Map.get(tables, "glyf", <<>>)

    loca_entries = if loca_format == 0, do: div(byte_size(loca), 2), else: div(byte_size(loca), 4)

    num_glyphs =
      case tables["maxp"] do
        <<_::32, n::16, _::binary>> -> n
        _ -> max(loca_entries - 1, 0)
      end

    num_glyphs =
      if glyf != <<>> and loca_entries > 0,
        do: min(num_glyphs, loca_entries - 1) |> max(0),
        else: num_glyphs

    num_hmetrics =
      case tables["hhea"] do
        <<_::binary-34, n::16, _::binary>> -> n
        _ -> 0
      end

    cmaps = parse_cmaps(Map.get(tables, "cmap", <<>>))
    post_names = parse_post(Map.get(tables, "post", <<>>))

    name_to_gid =
      case post_names do
        nil ->
          %{}

        names ->
          names
          |> Tuple.to_list()
          |> Enum.with_index()
          |> Enum.reduce(%{}, fn {name, gid}, acc -> Map.put_new(acc, name, gid) end)
      end

    cff =
      case tables["CFF "] do
        nil ->
          nil

        bytes ->
          case CFF.parse(bytes) do
            {:ok, c} -> c
            _ -> nil
          end
      end

    num_glyphs = if cff && num_glyphs == 0, do: cff.num_glyphs, else: num_glyphs

    %__MODULE__{
      tables: Map.take(tables, ["head", "maxp", "hhea", "OS/2"]),
      units_per_em: upem,
      loca_format: loca_format,
      num_glyphs: num_glyphs,
      loca: loca,
      glyf: glyf,
      cmaps: cmaps,
      post_names: post_names,
      name_to_gid: name_to_gid,
      hmtx: Map.get(tables, "hmtx", <<>>),
      num_hmetrics: num_hmetrics,
      cff: cff,
      reverse_unicode: reverse_unicode(cmaps)
    }
  end

  # ---------------------------------------------------------------- cmap

  # Subtables are expanded into `%{code => gid}` maps, so a few bytes of a
  # hostile font could ask for millions of entries (wide format 12/13 groups,
  # overlapping format 4 segments, many encoding records sharing one
  # subtable). The whole table gets a budget of @max_cmap_entries code
  # points, far above what a font with 65,535 glyphs and the usual four
  # Unicode records needs; what does not fit is left unmapped.
  @max_cmap_records 64
  @max_cmap_entries 524_288
  # format 12/13 groups of one subtable
  @max_subtable_entries 262_144

  defp parse_cmaps(<<_version::16, n::16, rest::binary>> = cmap) do
    n = min(n, @max_cmap_records)

    records =
      for <<p::16, e::16, off::32 <- binary_part(rest, 0, min(n * 8, byte_size(rest)))>>,
        do: {p, e, off}

    {cmaps, _parsed, _budget} =
      Enum.reduce(records, {%{}, %{}, @max_cmap_entries}, fn {p, e, off}, {acc, parsed, budget} ->
        if Map.has_key?(acc, {p, e}) or off >= byte_size(cmap) do
          {acc, parsed, budget}
        else
          # records often share a subtable: it is parsed once, but each
          # record that keeps it pays for its entries
          {map, parsed, budget} =
            case parsed do
              %{^off => map} when is_map(map) and map_size(map) <= budget ->
                {map, parsed, budget - map_size(map)}

              %{^off => _} ->
                {nil, parsed, budget}

              _ ->
                sub = binary_part(cmap, off, byte_size(cmap) - off)
                {map, left} = safe_subtable(sub, budget)
                {map, Map.put(parsed, off, map), left}
            end

          case map do
            map when is_map(map) and map_size(map) > 0 ->
              {Map.put(acc, {p, e}, map), parsed, budget}

            _ ->
              {acc, parsed, budget}
          end
        end
      end)

    cmaps
  rescue
    _ -> %{}
  end

  defp parse_cmaps(_), do: %{}

  # {map | nil, budget left}
  defp safe_subtable(sub, budget) do
    parse_subtable(sub, budget)
  rescue
    _ -> {nil, budget}
  end

  defp parse_subtable(<<0::16, _len::16, _lang::16, glyphs::binary-256, _::binary>>, budget)
       when budget >= 256 do
    map =
      for {gid, code} <- glyphs |> :binary.bin_to_list() |> Enum.with_index(),
          gid != 0,
          into: %{},
          do: {code, gid}

    {map, budget - 256}
  end

  defp parse_subtable(
         <<4::16, _len::16, _lang::16, seg_x2::16, _::binary-6, rest::binary>>,
         budget
       ) do
    seg = div(seg_x2, 2)

    <<ends::binary-size(seg_x2), _pad::16, starts::binary-size(seg_x2),
      deltas::binary-size(seg_x2), range_offsets::binary-size(seg_x2), glyph_ids::binary>> = rest

    ends = for <<v::16 <- ends>>, do: v
    starts = for <<v::16 <- starts>>, do: v
    deltas = for <<v::16 <- deltas>>, do: v
    offsets = for <<v::16 <- range_offsets>>, do: v

    # the segments of a well-formed subtable do not overlap: 65,535 codes at most
    allowed = min(budget, 0x10000)

    {map, left} =
      [ends, starts, deltas, offsets]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.reduce_while({%{}, allowed}, fn {{e, s, delta, ro}, i}, {acc, left} ->
        cond do
          left <= 0 ->
            {:halt, {acc, left}}

          s > e or s == 0xFFFF ->
            {:cont, {acc, left}}

          true ->
            last = min(min(e, 0xFFFE), s + left - 1)

            acc =
              Enum.reduce(s..last//1, acc, fn c, acc ->
                gid =
                  if ro == 0 do
                    band(c + delta, 0xFFFF)
                  else
                    idx = i + div(ro, 2) + (c - s) - seg

                    if idx >= 0 and 2 * idx + 2 <= byte_size(glyph_ids) do
                      <<_::binary-size(2 * idx), g::16, _::binary>> = glyph_ids
                      if g == 0, do: 0, else: band(g + delta, 0xFFFF)
                    else
                      0
                    end
                  end

                if gid != 0, do: Map.put(acc, c, gid), else: acc
              end)

            {:cont, {acc, left - max(last - s + 1, 0)}}
        end
      end)

    {map, budget - (allowed - left)}
  end

  defp parse_subtable(
         <<6::16, _len::16, _lang::16, first::16, count::16, rest::binary>>,
         budget
       ) do
    count = min(count, budget)
    gids = for <<g::16 <- binary_part(rest, 0, min(2 * count, byte_size(rest)))>>, do: g

    map =
      gids
      |> Enum.with_index(first)
      |> Enum.reduce(%{}, fn {g, c}, acc -> if g != 0, do: Map.put(acc, c, g), else: acc end)

    {map, budget - length(gids)}
  end

  defp parse_subtable(<<fmt::16, _::16, _len::32, _lang::32, n::32, rest::binary>>, budget)
       when fmt in [12, 13] do
    groups =
      for <<s::32, e::32, g::32 <- binary_part(rest, 0, min(12 * n, byte_size(rest)))>>,
        do: {s, e, g}

    allowed = min(budget, @max_subtable_entries)

    {map, left} =
      Enum.reduce_while(groups, {%{}, allowed}, fn {s, e, g}, {acc, left} ->
        if left <= 0 do
          {:halt, {acc, left}}
        else
          # guard against absurd ranges in broken fonts
          e = e |> min(s + 0x10000) |> min(s + left - 1)

          acc =
            Enum.reduce(s..e//1, acc, fn c, acc ->
              gid = if fmt == 12, do: g + (c - s), else: g
              if gid != 0, do: Map.put(acc, c, gid), else: acc
            end)

          {:cont, {acc, left - max(e - s + 1, 0)}}
        end
      end)

    {map, budget - (allowed - left)}
  end

  defp parse_subtable(_, budget), do: {nil, budget}

  defp reverse_unicode(cmaps) do
    table =
      Enum.find_value([{3, 10}, {3, 1}, {0, 4}, {0, 3}, {0, 1}, {0, 0}, {0, 6}], fn key ->
        cmaps[key]
      end)

    case table do
      nil ->
        %{}

      map ->
        map
        |> Enum.sort()
        |> Enum.reduce(%{}, fn {code, gid}, acc ->
          if code in 0xD800..0xDFFF or code >= 0x110000,
            do: acc,
            else: Map.put_new(acc, gid, code)
        end)
    end
  end

  @doc "Looks up `code` in the cmap subtable `{platform, encoding}`."
  @spec cmap_lookup(t(), {integer(), integer()}, non_neg_integer()) :: non_neg_integer() | nil
  def cmap_lookup(%__MODULE__{cmaps: cmaps}, key, code) do
    case cmaps do
      %{^key => map} -> Map.get(map, code)
      _ -> nil
    end
  end

  @doc "Looks up a Unicode code point in the font's Unicode cmap."
  @spec unicode_lookup(t(), non_neg_integer()) :: non_neg_integer() | nil
  def unicode_lookup(%__MODULE__{cmaps: cmaps}, cp) do
    Enum.find_value([{3, 10}, {3, 1}, {0, 4}, {0, 3}, {0, 1}, {0, 0}, {0, 6}], fn key ->
      case cmaps do
        %{^key => map} -> Map.get(map, cp)
        _ -> nil
      end
    end)
  end

  @doc "Whether the font has a Unicode cmap."
  def unicode_cmap?(%__MODULE__{cmaps: cmaps}),
    do:
      Enum.any?(
        [{3, 10}, {3, 1}, {0, 4}, {0, 3}, {0, 1}, {0, 0}, {0, 6}],
        &Map.has_key?(cmaps, &1)
      )

  # ---------------------------------------------------------------- post

  defp parse_post(<<0x00020000::32, _::binary-28, n::16, rest::binary>>) do
    idx_bytes = min(2 * n, byte_size(rest))
    <<indices::binary-size(idx_bytes), strings::binary>> = rest
    indices = for <<i::16 <- indices>>, do: i
    custom = pascal_strings(strings, []) |> List.to_tuple()

    indices
    |> Enum.map(fn
      i when i < 258 -> elem(@mac_tuple, i)
      i when i - 258 < tuple_size(custom) -> elem(custom, i - 258)
      _ -> nil
    end)
    |> List.to_tuple()
  end

  defp parse_post(<<0x00010000::32, _::binary>>), do: @mac_tuple
  defp parse_post(_), do: nil

  defp pascal_strings(<<len, s::binary-size(len), rest::binary>>, acc),
    do: pascal_strings(rest, [s | acc])

  defp pascal_strings(_, acc), do: Enum.reverse(acc)

  @doc "The post-table name of a glyph, or nil."
  def glyph_name(%__MODULE__{post_names: nil}, _gid), do: nil

  def glyph_name(%__MODULE__{post_names: names}, gid) when gid >= 0 and gid < tuple_size(names),
    do: elem(names, gid)

  def glyph_name(_, _), do: nil

  @doc "Glyph id of a post-table name, or nil."
  def name_gid(%__MODULE__{name_to_gid: m}, name), do: Map.get(m, name)

  # ---------------------------------------------------------------- hmtx

  @doc "Advance width of a glyph in font units, or nil."
  def advance(%__MODULE__{hmtx: hmtx, num_hmetrics: n}, gid) when n > 0 do
    i = min(gid, n - 1)

    case hmtx do
      <<_::binary-size(4 * i), aw::16, _::binary>> -> aw
      _ -> nil
    end
  end

  def advance(_, _), do: nil

  # ---------------------------------------------------------------- glyf

  # One glyph may reference at most @max_components components over its
  # whole composite tree and produce at most @max_points points (a simple
  # glyph has up to 65,535); past that it has no outline. Without this, a
  # few hundred bytes of nested composites multiply into billions of points.
  @max_components 256
  @max_points 100_000

  @doc """
  The outline of glyph `gid` in em units (font units / unitsPerEm), or nil
  if the glyph does not exist. CFF-flavored fonts delegate to their CFF.
  """
  @spec glyph(t(), non_neg_integer()) :: [Outline.cmd()] | nil
  def glyph(%__MODULE__{cff: %CFF{} = cff}, gid), do: CFF.glyph(cff, gid)

  def glyph(%__MODULE__{} = tt, gid) do
    case contours(tt, gid, 0, {@max_components, @max_points}) do
      {nil, _} ->
        nil

      {contours, _} ->
        contours |> Enum.flat_map(&contour_path/1) |> Outline.scale(1 / tt.units_per_em)
    end
  rescue
    _ -> nil
  catch
    # over the per-glyph budget: no outline, as for a broken glyph
    :throw, :glyph_budget -> nil
  end

  defp glyph_data(%__MODULE__{loca: loca, glyf: glyf, loca_format: fmt, num_glyphs: n}, gid) do
    if gid < 0 or gid >= n do
      nil
    else
      {start, stop} =
        if fmt == 0 do
          case loca do
            <<_::binary-size(2 * gid), a::16, b::16, _::binary>> -> {a * 2, b * 2}
            _ -> {0, 0}
          end
        else
          case loca do
            <<_::binary-size(4 * gid), a::32, b::32, _::binary>> -> {a, b}
            _ -> {0, 0}
          end
        end

      cond do
        stop <= start -> <<>>
        start >= byte_size(glyf) -> <<>>
        true -> binary_part(glyf, start, min(stop, byte_size(glyf)) - start)
      end
    end
  end

  # contours as lists of {x, y, on_curve?} in font units, with the budget
  # `{components, points}` left
  defp contours(_tt, _gid, depth, budget) when depth > 8, do: {[], budget}

  defp contours(tt, gid, depth, {comps, points} = budget) do
    case glyph_data(tt, gid) do
      nil ->
        {nil, budget}

      <<>> ->
        {[], budget}

      <<n::signed-16, _bbox::binary-8, rest::binary>> when n >= 0 ->
        {contours, points} = simple(rest, n, points)
        {contours, {comps, points}}

      <<_n::signed-16, _bbox::binary-8, rest::binary>> ->
        composite(tt, rest, depth, [], budget)

      _ ->
        {[], budget}
    end
  end

  defp simple(_data, 0, budget), do: {[], budget}

  defp simple(data, n, budget) do
    <<ends::binary-size(2 * n), ilen::16, _instr::binary-size(ilen), rest::binary>> = data
    ends = for <<e::16 <- ends>>, do: e
    count = List.last(ends) + 1
    if count > budget, do: throw(:glyph_budget)
    {flags, rest} = read_flags(rest, count, [])
    {xs, rest} = read_coords(rest, flags, 2, 16, 0, [])
    {ys, _rest} = read_coords(rest, flags, 4, 32, 0, [])

    points =
      Enum.zip([xs, ys, flags])
      |> Enum.map(fn {x, y, f} -> {x, y, band(f, 1) == 1} end)
      |> List.to_tuple()

    split_contours(points, ends, 0, [], budget)
  end

  defp read_flags(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp read_flags(<<f, rest::binary>>, n, acc) do
    if band(f, 8) != 0 do
      <<repeat, rest2::binary>> = rest
      times = min(repeat + 1, n)
      read_flags(rest2, n - times, List.duplicate(f, times) ++ acc)
    else
      read_flags(rest, n - 1, [f | acc])
    end
  end

  defp read_flags(<<>>, n, acc), do: {Enum.reverse(acc) ++ List.duplicate(1, n), <<>>}

  defp read_coords(rest, [], _short, _same, _cur, acc), do: {Enum.reverse(acc), rest}

  defp read_coords(rest, [f | flags], short, same, cur, acc) do
    cond do
      band(f, short) != 0 ->
        case rest do
          <<d, r::binary>> ->
            v = if band(f, same) != 0, do: cur + d, else: cur - d
            read_coords(r, flags, short, same, v, [v | acc])

          _ ->
            read_coords(<<>>, flags, short, same, cur, [cur | acc])
        end

      band(f, same) != 0 ->
        read_coords(rest, flags, short, same, cur, [cur | acc])

      true ->
        case rest do
          <<d::signed-16, r::binary>> ->
            v = cur + d
            read_coords(r, flags, short, same, v, [v | acc])

          _ ->
            read_coords(<<>>, flags, short, same, cur, [cur | acc])
        end
    end
  end

  # `points` is a tuple; each contour is its points `from..e`. End points
  # that go backwards make contours overlap, so the points handed out are
  # counted against the budget rather than the points of the glyph.
  defp split_contours(_points, [], _from, acc, budget), do: {Enum.reverse(acc), budget}

  defp split_contours(points, [e | ends], from, acc, budget) do
    last = min(e, tuple_size(points) - 1)
    budget = budget - max(last - from + 1, 0)
    if budget < 0, do: throw(:glyph_budget)
    contour = for i <- from..last//1, do: elem(points, i)
    acc = if contour == [], do: acc, else: [contour | acc]
    split_contours(points, ends, e + 1, acc, budget)
  end

  defp composite(_tt, _data, _depth, _acc, {comps, _points}) when comps <= 0,
    do: throw(:glyph_budget)

  defp composite(tt, data, depth, acc, {comps, points}) do
    case data do
      <<flags::16, gid::16, rest::binary>> ->
        xy? = band(flags, 2) != 0

        {a1, a2, rest} =
          if band(flags, 1) != 0 do
            if xy? do
              <<a::signed-16, b::signed-16, r::binary>> = rest
              {a, b, r}
            else
              <<a::16, b::16, r::binary>> = rest
              {a, b, r}
            end
          else
            if xy? do
              <<a::signed-8, b::signed-8, r::binary>> = rest
              {a, b, r}
            else
              <<a, b, r::binary>> = rest
              {a, b, r}
            end
          end

        {m, rest} =
          cond do
            band(flags, 8) != 0 ->
              <<s::signed-16, r::binary>> = rest
              {{f2d14(s), 0.0, 0.0, f2d14(s)}, r}

            band(flags, 0x40) != 0 ->
              <<sx::signed-16, sy::signed-16, r::binary>> = rest
              {{f2d14(sx), 0.0, 0.0, f2d14(sy)}, r}

            band(flags, 0x80) != 0 ->
              <<a::signed-16, b::signed-16, c::signed-16, d::signed-16, r::binary>> = rest
              {{f2d14(a), f2d14(b), f2d14(c), f2d14(d)}, r}

            true ->
              {{1.0, 0.0, 0.0, 1.0}, rest}
          end

        {dx, dy} = if xy?, do: {a1, a2}, else: {0, 0}
        {xx, xy, yx, yy} = m

        {part, budget} = contours(tt, gid, depth + 1, {comps - 1, points})

        component =
          (part || [])
          |> Enum.map(fn contour ->
            Enum.map(contour, fn {x, y, on} ->
              {xx * x + yx * y + dx, xy * x + yy * y + dy, on}
            end)
          end)

        acc = Enum.reverse(component, acc)

        if band(flags, 0x20) != 0,
          do: composite(tt, rest, depth, acc, budget),
          else: {Enum.reverse(acc), budget}

      _ ->
        {Enum.reverse(acc), {comps, points}}
    end
  end

  defp f2d14(v), do: v / 16384

  @doc false
  # Converts one contour of on/off-curve points to path commands with
  # quadratic segments raised to cubics.
  def contour_path([]), do: []

  def contour_path(points) do
    {start, ordered} =
      case Enum.find_index(points, fn {_, _, on} -> on end) do
        nil ->
          # all off-curve: start at the midpoint of the first two
          [{x0, y0, _}, {x1, y1, _} | _] = points ++ points
          {{(x0 + x1) / 2, (y0 + y1) / 2}, points}

        i ->
          {a, b} = Enum.split(points, i)
          [{sx, sy, _} | rest] = b ++ a
          {{sx, sy}, rest}
      end

    {sx, sy} = start

    {cmds, cur, pending} =
      Enum.reduce(ordered, {[{:move, sx, sy}], start, nil}, fn
        {x, y, true}, {cmds, _cur, nil} ->
          {[{:line, x, y} | cmds], {x, y}, nil}

        {x, y, true}, {cmds, cur, {qx, qy}} ->
          {[quad(cur, {qx, qy}, {x, y}) | cmds], {x, y}, nil}

        {x, y, false}, {cmds, cur, nil} ->
          {cmds, cur, {x, y}}

        {x, y, false}, {cmds, cur, {qx, qy}} ->
          mid = {(qx + x) / 2, (qy + y) / 2}
          {[quad(cur, {qx, qy}, mid) | cmds], mid, {x, y}}
      end)

    cmds =
      case pending do
        nil -> cmds
        q -> [quad(cur, q, start) | cmds]
      end

    Enum.reverse([:close | cmds])
  end

  defp quad({x0, y0}, {qx, qy}, {x, y}) do
    {:curve, x0 + 2 / 3 * (qx - x0), y0 + 2 / 3 * (qy - y0), x + 2 / 3 * (qx - x),
     y + 2 / 3 * (qy - y), x / 1, y / 1}
  end
end
