defmodule EmbedPdf.Font.CFF do
  @moduledoc """
  Compact Font Format fonts (Adobe Technical Note #5176): bare CFF from
  `FontFile3` (`Type1C`, `CIDFontType0C`) or the `CFF ` table of an
  OpenType font. Name-keyed and CID-keyed (FDArray/FDSelect) fonts, with
  Type 2 charstrings interpreted by `EmbedPdf.Font.CFF.Type2`.
  """

  import Bitwise

  alias EmbedPdf.Font.{Encoding, Outline}
  alias EmbedPdf.Font.CFF.Type2

  defstruct charstrings: {<<>>, {}},
            gsubrs: {<<>>, {}},
            subrs: {<<>>, {}},
            strings: {<<>>, {}},
            charset: {},
            name_to_gid: %{},
            cid?: false,
            cid_to_gid: %{},
            fds: {},
            fd_select: nil,
            matrix: [0.001, 0.0, 0.0, 0.001, 0.0, 0.0],
            num_glyphs: 0,
            encoding: :standard,
            charstring_type: 2,
            default_width: 0,
            nominal_width: 0

  @type t :: %__MODULE__{}

  @standard_strings ~w(.notdef space exclam quotedbl numbersign dollar percent ampersand
    quoteright parenleft parenright asterisk plus comma hyphen period slash zero one two
    three four five six seven eight nine colon semicolon less equal greater question at A
    B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright
    asciicircum underscore quoteleft a b c d e f g h i j k l m n o p q r s t u v w x y z
    braceleft bar braceright asciitilde exclamdown cent sterling fraction yen florin
    section currency quotesingle quotedblleft guillemotleft guilsinglleft guilsinglright
    fi fl endash dagger daggerdbl periodcentered paragraph bullet quotesinglbase
    quotedblbase quotedblright guillemotright ellipsis perthousand questiondown grave
    acute circumflex tilde macron breve dotaccent dieresis ring cedilla hungarumlaut
    ogonek caron emdash AE ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash
    oslash oe germandbls onesuperior logicalnot mu trademark Eth onehalf plusminus Thorn
    onequarter divide brokenbar degree thorn threequarters twosuperior registered minus
    eth multiply threesuperior copyright Aacute Acircumflex Adieresis Agrave Aring Atilde
    Ccedilla Eacute Ecircumflex Edieresis Egrave Iacute Icircumflex Idieresis Igrave
    Ntilde Oacute Ocircumflex Odieresis Ograve Otilde Scaron Uacute Ucircumflex Udieresis
    Ugrave Yacute Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde
    ccedilla eacute ecircumflex edieresis egrave iacute icircumflex idieresis igrave
    ntilde oacute ocircumflex odieresis ograve otilde scaron uacute ucircumflex udieresis
    ugrave yacute ydieresis zcaron exclamsmall Hungarumlautsmall dollaroldstyle
    dollarsuperior ampersandsmall Acutesmall parenleftsuperior parenrightsuperior
    twodotenleader onedotenleader zerooldstyle oneoldstyle twooldstyle threeoldstyle
    fouroldstyle fiveoldstyle sixoldstyle sevenoldstyle eightoldstyle nineoldstyle
    commasuperior threequartersemdash periodsuperior questionsmall asuperior bsuperior
    centsuperior dsuperior esuperior isuperior lsuperior msuperior nsuperior osuperior
    rsuperior ssuperior tsuperior ff ffi ffl parenleftinferior parenrightinferior
    Circumflexsmall hyphensuperior Gravesmall Asmall Bsmall Csmall Dsmall Esmall Fsmall
    Gsmall Hsmall Ismall Jsmall Ksmall Lsmall Msmall Nsmall Osmall Psmall Qsmall Rsmall
    Ssmall Tsmall Usmall Vsmall Wsmall Xsmall Ysmall Zsmall colonmonetary onefitted rupiah
    Tildesmall exclamdownsmall centoldstyle Lslashsmall Scaronsmall Zcaronsmall
    Dieresissmall Brevesmall Caronsmall Dotaccentsmall Macronsmall figuredash
    hypheninferior Ogoneksmall Ringsmall Cedillasmall questiondownsmall oneeighth
    threeeighths fiveeighths seveneighths onethird twothirds zerosuperior foursuperior
    fivesuperior sixsuperior sevensuperior eightsuperior ninesuperior zeroinferior
    oneinferior twoinferior threeinferior fourinferior fiveinferior sixinferior
    seveninferior eightinferior nineinferior centinferior dollarinferior periodinferior
    commainferior Agravesmall Aacutesmall Acircumflexsmall Atildesmall Adieresissmall
    Aringsmall AEsmall Ccedillasmall Egravesmall Eacutesmall Ecircumflexsmall
    Edieresissmall Igravesmall Iacutesmall Icircumflexsmall Idieresissmall Ethsmall
    Ntildesmall Ogravesmall Oacutesmall Ocircumflexsmall Otildesmall Odieresissmall
    OEsmall Oslashsmall Ugravesmall Uacutesmall Ucircumflexsmall Udieresissmall
    Yacutesmall Thornsmall Ydieresissmall 001.000 001.001 001.002 001.003 Black Bold Book
    Light Medium Regular Roman Semibold)

  391 = length(@standard_strings)
  @standard_tuple List.to_tuple(@standard_strings)
  @standard_sid @standard_strings |> Enum.with_index() |> Map.new()

  @doc "Name of a standard string id, or nil."
  def standard_string(sid) when sid >= 0 and sid < 391, do: elem(@standard_tuple, sid)
  def standard_string(_), do: nil

  @doc "Whether the bytes look like a bare CFF font."
  def cff?(<<1, _minor, hdr, off, _::binary>>) when hdr >= 4 and off in 1..4, do: true
  def cff?(_), do: false

  @doc "Parses CFF bytes."
  @spec parse(binary()) :: {:ok, t()} | :error
  def parse(<<_major, _minor, hdr_size, _off_size, _::binary>> = data) when hdr_size >= 4 do
    rest = binary_part(data, hdr_size, byte_size(data) - hdr_size)
    {_names, rest} = read_index(rest)
    {tops, rest} = read_index(rest)
    {strings, rest} = read_index(rest)
    {gsubrs, _rest} = read_index(rest)

    top = tops |> index_get(0) |> parse_dict()
    charstrings = index_at(data, first(top[17]))
    n = index_count(charstrings)

    if n == 0 do
      :error
    else
      cid? = Map.has_key?(top, {12, 30})
      charset = parse_charset(data, first(top[15]) || 0, n)
      {private, subrs} = private(data, top[18])
      top_matrix = matrix(top[{12, 7}])

      base = %__MODULE__{
        charstrings: charstrings,
        gsubrs: gsubrs,
        subrs: subrs,
        strings: strings,
        charset: charset,
        cid?: cid?,
        num_glyphs: n,
        matrix: top_matrix || [0.001, 0.0, 0.0, 0.001, 0.0, 0.0],
        charstring_type: first(top[{12, 6}]) || 2,
        default_width: first(private[20]) || 0,
        nominal_width: first(private[21]) || 0
      }

      cff =
        if cid? do
          fds = parse_fd_array(data, top[{12, 36}], top_matrix)
          fd_select = parse_fd_select(data, first(top[{12, 37}]), n)

          cid_to_gid =
            charset
            |> Tuple.to_list()
            |> Enum.with_index()
            |> Enum.reduce(%{}, fn {cid, gid}, acc -> Map.put_new(acc, cid, gid) end)

          %{base | fds: fds, fd_select: fd_select, cid_to_gid: cid_to_gid}
        else
          names =
            charset
            |> Tuple.to_list()
            |> Enum.with_index()
            |> Enum.reduce(%{}, fn {sid, gid}, acc ->
              Map.put_new(acc, sid_name(strings, sid), gid)
            end)

          base = %{base | name_to_gid: names}
          %{base | encoding: parse_encoding(data, first(top[16]) || 0, base)}
        end

      {:ok, cff}
    end
  rescue
    _ -> :error
  end

  def parse(_), do: :error

  defp first([v | _]), do: v
  defp first(_), do: nil

  defp matrix([_, _, _, _, _, _] = m), do: Enum.map(m, &(&1 / 1))
  defp matrix(_), do: nil

  # ---------------------------------------------------------------- INDEX

  @doc false
  def read_index(<<0::16, rest::binary>>), do: {{<<>>, {}}, rest}

  def read_index(<<count::16, off_size, rest::binary>>) when off_size in 1..4 do
    n = count + 1
    <<offs::binary-size(n * off_size), rest::binary>> = rest
    offsets = for <<o::size(off_size)-unit(8) <- offs>>, do: o
    len = max(List.last(offsets) - 1, 0)
    len = min(len, byte_size(rest))
    <<data::binary-size(len), rest::binary>> = rest
    {{data, List.to_tuple(offsets)}, rest}
  end

  def read_index(_), do: {{<<>>, {}}, <<>>}

  defp index_at(_data, nil), do: {<<>>, {}}

  defp index_at(data, off) when is_integer(off) and off >= 0 and off < byte_size(data),
    do: data |> binary_part(off, byte_size(data) - off) |> read_index() |> elem(0)

  defp index_at(_, _), do: {<<>>, {}}

  @doc false
  def index_count({_, offs}), do: max(tuple_size(offs) - 1, 0)

  @doc false
  def index_get({data, offs}, i) when is_integer(i) and i >= 0 and i < tuple_size(offs) - 1 do
    a = elem(offs, i) - 1
    b = elem(offs, i + 1) - 1
    if a >= 0 and b >= a and b <= byte_size(data), do: binary_part(data, a, b - a), else: nil
  end

  def index_get(_, _), do: nil

  # ---------------------------------------------------------------- DICT

  @doc false
  def parse_dict(nil), do: %{}
  def parse_dict(bin), do: dict(bin, [], %{})

  defp dict(<<>>, _ops, acc), do: acc

  defp dict(<<12, b1, rest::binary>>, ops, acc),
    do: dict(rest, [], Map.put(acc, {12, b1}, Enum.reverse(ops)))

  defp dict(<<b0, rest::binary>>, ops, acc) when b0 <= 21,
    do: dict(rest, [], Map.put(acc, b0, Enum.reverse(ops)))

  defp dict(<<28, v::signed-16, rest::binary>>, ops, acc), do: dict(rest, [v | ops], acc)
  defp dict(<<29, v::signed-32, rest::binary>>, ops, acc), do: dict(rest, [v | ops], acc)

  defp dict(<<30, rest::binary>>, ops, acc) do
    {v, rest} = real(rest, [])
    dict(rest, [v | ops], acc)
  end

  defp dict(<<b0, rest::binary>>, ops, acc) when b0 in 32..246,
    do: dict(rest, [b0 - 139 | ops], acc)

  defp dict(<<b0, b1, rest::binary>>, ops, acc) when b0 in 247..250,
    do: dict(rest, [(b0 - 247) * 256 + b1 + 108 | ops], acc)

  defp dict(<<b0, b1, rest::binary>>, ops, acc) when b0 in 251..254,
    do: dict(rest, [-(b0 - 251) * 256 - b1 - 108 | ops], acc)

  defp dict(<<_, rest::binary>>, ops, acc), do: dict(rest, ops, acc)

  defp real(<<b, rest::binary>>, acc) do
    hi = b >>> 4
    lo = b &&& 0xF

    case {nibble(hi), nibble(lo)} do
      {:end, _} -> {to_real(acc), rest}
      {h, :end} -> {to_real([h | acc]), rest}
      {h, l} -> real(rest, [l, h | acc])
    end
  end

  defp real(<<>>, acc), do: {to_real(acc), <<>>}

  defp nibble(n) when n <= 9, do: Integer.to_string(n)
  defp nibble(0xA), do: "."
  defp nibble(0xB), do: "E"
  defp nibble(0xC), do: "E-"
  defp nibble(0xE), do: "-"
  defp nibble(0xF), do: :end
  defp nibble(_), do: ""

  defp to_real(acc) do
    s = acc |> Enum.reverse() |> Enum.join()
    s = if String.starts_with?(s, "."), do: "0" <> s, else: s
    s = String.replace(s, "-.", "-0.")

    case Float.parse(s) do
      {f, _} ->
        f

      :error ->
        case Integer.parse(s) do
          {i, _} -> i / 1
          :error -> 0.0
        end
    end
  end

  # ---------------------------------------------------------------- charset / encoding

  defp parse_charset(_data, off, n) when off in [0, 1, 2] do
    # predefined charsets: ISOAdobe (and an identity approximation of Expert)
    List.to_tuple(Enum.to_list(0..(n - 1)//1))
  end

  defp parse_charset(data, off, n) when off < byte_size(data) do
    <<format, rest::binary>> = binary_part(data, off, byte_size(data) - off)
    sids = charset_entries(format, rest, n - 1, [])
    List.to_tuple([0 | sids])
  rescue
    _ -> List.to_tuple(Enum.to_list(0..(n - 1)//1))
  end

  defp parse_charset(_data, _off, n), do: List.to_tuple(Enum.to_list(0..(n - 1)//1))

  defp charset_entries(_format, _rest, left, acc) when left <= 0,
    do: acc |> Enum.reverse() |> Enum.take(max(length(acc), 0))

  defp charset_entries(0, <<sid::16, rest::binary>>, left, acc),
    do: charset_entries(0, rest, left - 1, [sid | acc])

  defp charset_entries(1, <<first::16, nleft, rest::binary>>, left, acc) do
    take = min(nleft + 1, left)

    charset_entries(
      1,
      rest,
      left - take,
      Enum.reverse(first..(first + take - 1)//1 |> Enum.to_list(), acc)
    )
  end

  defp charset_entries(2, <<first::16, nleft::16, rest::binary>>, left, acc) do
    take = min(nleft + 1, left)

    charset_entries(
      2,
      rest,
      left - take,
      Enum.reverse(first..(first + take - 1)//1 |> Enum.to_list(), acc)
    )
  end

  defp charset_entries(_, _, _, acc), do: Enum.reverse(acc)

  defp parse_encoding(_data, 0, _cff), do: :standard
  defp parse_encoding(_data, 1, _cff), do: :expert

  defp parse_encoding(data, off, cff) when off < byte_size(data) do
    <<format, rest::binary>> = binary_part(data, off, byte_size(data) - off)

    {map, rest} =
      case format &&& 0x7F do
        0 ->
          <<n, codes::binary-size(n), rest::binary>> = rest
          {codes |> :binary.bin_to_list() |> Enum.with_index(1) |> Map.new(), rest}

        1 ->
          <<n, rest::binary>> = rest
          <<ranges::binary-size(2 * n), rest::binary>> = rest

          {map, _gid} =
            for <<first, nleft <- ranges>>, reduce: {%{}, 1} do
              {m, gid} ->
                Enum.reduce(0..nleft//1, {m, gid}, fn i, {m, g} ->
                  {Map.put_new(m, first + i, g), g + 1}
                end)
            end

          {map, rest}

        _ ->
          {%{}, <<>>}
      end

    map =
      if (format &&& 0x80) != 0 do
        case rest do
          <<n, sups::binary-size(3 * n), _::binary>> ->
            sid_to_gid =
              cff.charset |> Tuple.to_list() |> Enum.with_index() |> Map.new()

            for <<code, sid::16 <- sups>>, reduce: map do
              m -> if g = sid_to_gid[sid], do: Map.put(m, code, g), else: m
            end

          _ ->
            map
        end
      else
        map
      end

    {:custom, map}
  rescue
    _ -> :standard
  end

  defp parse_encoding(_, _, _), do: :standard

  @doc "Name of a string id."
  def sid_name(strings, sid) when sid >= 391, do: index_get(strings, sid - 391) || "sid#{sid}"
  def sid_name(_strings, sid), do: standard_string(sid) || ".notdef"

  @doc "Glyph name of `gid` (name-keyed fonts only)."
  def glyph_name(%__MODULE__{cid?: true}, _gid), do: nil

  def glyph_name(%__MODULE__{charset: cs, strings: s}, gid)
      when gid >= 0 and gid < tuple_size(cs),
      do: sid_name(s, elem(cs, gid))

  def glyph_name(_, _), do: nil

  @doc "Glyph id of a glyph name (name-keyed fonts)."
  def name_gid(%__MODULE__{name_to_gid: m}, name), do: Map.get(m, name)

  @doc "Glyph id of a CID (CID-keyed fonts); identity otherwise."
  def cid_gid(%__MODULE__{cid?: true, cid_to_gid: m}, cid), do: Map.get(m, cid)
  def cid_gid(%__MODULE__{num_glyphs: n}, cid) when cid < n, do: cid
  def cid_gid(_, _), do: nil

  @doc "The font's own encoding as `%{code => glyph_name}` (nil for CID-keyed / expert)."
  def builtin_encoding(%__MODULE__{cid?: true}), do: nil
  def builtin_encoding(%__MODULE__{encoding: :standard}), do: Encoding.named("StandardEncoding")
  def builtin_encoding(%__MODULE__{encoding: :expert}), do: nil

  def builtin_encoding(%__MODULE__{encoding: {:custom, map}} = cff),
    do: Map.new(map, fn {code, gid} -> {code, glyph_name(cff, gid)} end)

  @doc "Glyph id for a code through the font's own encoding."
  def code_gid(%__MODULE__{encoding: {:custom, map}}, code), do: Map.get(map, code)

  def code_gid(%__MODULE__{encoding: :standard} = cff, code) do
    case Map.get(Encoding.named("StandardEncoding"), code) do
      nil -> nil
      name -> name_gid(cff, name)
    end
  end

  def code_gid(_, _), do: nil

  # ---------------------------------------------------------------- private / FDs

  defp private(data, [size, off])
       when is_integer(size) and is_integer(off) and off + size <= byte_size(data) and size >= 0 do
    dict = data |> binary_part(off, size) |> parse_dict()

    subrs =
      case dict[19] do
        [rel | _] when is_integer(rel) -> index_at(data, off + rel)
        _ -> {<<>>, {}}
      end

    {dict, subrs}
  end

  defp private(_data, _), do: {%{}, {<<>>, {}}}

  defp parse_fd_array(data, [off | _], top_matrix) when is_integer(off) do
    fd_index = index_at(data, off)

    for i <- 0..(index_count(fd_index) - 1)//1 do
      fd = fd_index |> index_get(i) |> parse_dict()
      {_priv, subrs} = private(data, fd[18])

      fd_matrix = matrix(fd[{12, 7}])

      m =
        cond do
          fd_matrix && top_matrix -> multiply(fd_matrix, top_matrix)
          fd_matrix -> fd_matrix
          top_matrix -> top_matrix
          true -> [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]
        end

      %{subrs: subrs, matrix: m}
    end
    |> List.to_tuple()
  end

  defp parse_fd_array(_, _, _), do: {}

  defp multiply([a1, b1, c1, d1, e1, f1], [a2, b2, c2, d2, e2, f2]) do
    [
      a1 * a2 + b1 * c2,
      a1 * b2 + b1 * d2,
      c1 * a2 + d1 * c2,
      c1 * b2 + d1 * d2,
      e1 * a2 + f1 * c2 + e2,
      e1 * b2 + f1 * d2 + f2
    ]
  end

  defp parse_fd_select(data, off, n) when is_integer(off) and off < byte_size(data) do
    case binary_part(data, off, byte_size(data) - off) do
      <<0, fds::binary-size(n), _::binary>> ->
        fds

      <<3, nranges::16, rest::binary>> ->
        ranges =
          for <<first::16, fd <- binary_part(rest, 0, min(3 * nranges, byte_size(rest)))>>,
            do: {first, fd}

        <<_::binary-size(3 * nranges), sentinel::16, _::binary>> = rest
        bounds = ranges |> Enum.drop(1) |> Enum.map(&elem(&1, 0)) |> Kernel.++([sentinel])

        ranges
        |> Enum.zip(bounds)
        |> Enum.reduce([], fn {{first, fd}, stop}, acc ->
          [:binary.copy(<<fd>>, max(stop - first, 0)) | acc]
        end)
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp parse_fd_select(_, _, _), do: nil

  defp fd_of(%__MODULE__{fd_select: sel, fds: fds}, gid) do
    fd =
      if is_binary(sel) and gid < byte_size(sel), do: :binary.at(sel, gid), else: 0

    if fd < tuple_size(fds), do: elem(fds, fd), else: nil
  end

  # ---------------------------------------------------------------- glyphs

  @doc """
  The advance width of glyph `gid` in text space for size 1 (name-keyed
  fonts), from the width its charstring carries or the font's default.
  """
  @spec advance(t(), non_neg_integer()) :: float() | nil
  def advance(%__MODULE__{charstring_type: 2, cid?: false} = cff, gid) when is_integer(gid) do
    [a | _] = cff.matrix

    case index_get(cff.charstrings, gid) do
      nil ->
        nil

      cs ->
        ctx = %{gsubrs: cff.gsubrs, subrs: cff.subrs, seac: fn _ -> nil end}

        case Type2.width(cs, ctx) do
          {:ok, w} -> (cff.nominal_width + w) * a
          :default -> cff.default_width * a
          :unknown -> nil
        end
    end
  rescue
    _ -> nil
  end

  def advance(_, _), do: nil

  @doc """
  Outline of glyph `gid` in text space for size 1 (FontMatrix applied),
  or nil when it does not exist.
  """
  @spec glyph(t(), non_neg_integer()) :: [Outline.cmd()] | nil
  def glyph(%__MODULE__{charstring_type: 2} = cff, gid) when is_integer(gid) do
    case index_get(cff.charstrings, gid) do
      nil ->
        nil

      cs ->
        {subrs, matrix} =
          if cff.cid? do
            case fd_of(cff, gid) do
              nil -> {cff.subrs, cff.matrix}
              fd -> {fd.subrs, fd.matrix}
            end
          else
            {cff.subrs, cff.matrix}
          end

        ctx = %{
          gsubrs: cff.gsubrs,
          subrs: subrs,
          seac: fn code -> seac_charstring(cff, code) end
        }

        case Type2.run(cs, ctx) do
          {:ok, cmds} -> Outline.transform(cmds, matrix)
          :error -> nil
        end
    end
  rescue
    _ -> nil
  end

  def glyph(_, _), do: nil

  defp seac_charstring(cff, code) do
    with name when is_binary(name) <- Map.get(Encoding.named("StandardEncoding"), code),
         gid when is_integer(gid) <- name_gid(cff, name) do
      index_get(cff.charstrings, gid)
    else
      _ -> nil
    end
  end

  @doc false
  def standard_sid(name), do: Map.get(@standard_sid, name)
end

defmodule EmbedPdf.Font.CFF.Type2 do
  @moduledoc """
  Type 2 charstring interpreter (Adobe Technical Note #5177). Produces an
  outline in charstring units; hints are skipped.
  """

  @max_ops 100_000

  @doc """
  Runs a charstring. `ctx` has `:gsubrs` and `:subrs` (CFF INDEX tuples)
  and `:seac` (code → charstring or nil, for accented `endchar`).
  """
  @spec run(binary(), map()) :: {:ok, list()} | :error
  def run(cs, ctx) do
    st = new_state()

    case exec(cs, st, ctx, 0) do
      {:error, _} -> :error
      {_, st} -> {:ok, finish(st)}
    end
  rescue
    _ -> :error
  end

  @doc """
  The width operand a charstring opens with: `{:ok, w}` (to add to
  nominalWidthX), `:default` (the glyph has the default width) or
  `:unknown` (the charstring could not be run). `ctx` as in `run/2`.
  """
  @spec width(binary(), map()) :: {:ok, number()} | :default | :unknown
  def width(cs, ctx) do
    case exec(cs, new_state(), ctx, 0) do
      {:error, _} -> :unknown
      {_, %{width: :default}} -> :default
      {_, %{width: w}} when is_number(w) -> {:ok, w}
    end
  rescue
    _ -> :unknown
  end

  defp new_state,
    do: %{
      x: 0.0,
      y: 0.0,
      stack: [],
      stems: 0,
      width?: false,
      width: :default,
      path: [],
      open?: false,
      ops: 0,
      trans: %{},
      seac: nil
    }

  defp finish(st) do
    st = close(st)
    base = Enum.reverse(st.path)

    case st.seac do
      nil -> base
      extra -> base ++ extra
    end
  end

  defp bias(index) do
    n = EmbedPdf.Font.CFF.index_count(index)

    cond do
      n < 1240 -> 107
      n < 33900 -> 1131
      true -> 32768
    end
  end

  defp exec(_cs, %{ops: ops} = st, _ctx, _depth) when ops > @max_ops, do: {:error, st}
  defp exec(_cs, st, _ctx, depth) when depth > 12, do: {:error, st}
  defp exec(<<>>, st, _ctx, _depth), do: {:eof, st}

  # numbers
  defp exec(<<28, v::signed-16, rest::binary>>, st, ctx, d), do: exec(rest, push(st, v), ctx, d)

  defp exec(<<255, v::signed-32, rest::binary>>, st, ctx, d),
    do: exec(rest, push(st, v / 65536), ctx, d)

  defp exec(<<b, rest::binary>>, st, ctx, d) when b in 32..246,
    do: exec(rest, push(st, b - 139), ctx, d)

  defp exec(<<b, b1, rest::binary>>, st, ctx, d) when b in 247..250,
    do: exec(rest, push(st, (b - 247) * 256 + b1 + 108), ctx, d)

  defp exec(<<b, b1, rest::binary>>, st, ctx, d) when b in 251..254,
    do: exec(rest, push(st, -(b - 251) * 256 - b1 - 108), ctx, d)

  # hints
  defp exec(<<op, rest::binary>>, st, ctx, d) when op in [1, 3, 18, 23] do
    {args, st} = take_width(st, args(st), :even)

    exec(
      rest,
      %{clear(st) | stems: st.stems + div(length(args), 2), width?: true, ops: st.ops + 1},
      ctx,
      d
    )
  end

  defp exec(<<op, rest::binary>>, st, ctx, d) when op in [19, 20] do
    {args, st} = take_width(st, args(st), :even)
    stems = st.stems + div(length(args), 2)
    skip = div(stems + 7, 8)

    rest =
      if byte_size(rest) >= skip, do: binary_part(rest, skip, byte_size(rest) - skip), else: <<>>

    exec(rest, %{clear(st) | stems: stems, width?: true, ops: st.ops + 1}, ctx, d)
  end

  # moves
  defp exec(<<21, rest::binary>>, st, ctx, d) do
    {args, st} = take_width(st, args(st), 2)
    [dx, dy | _] = args ++ [0, 0]
    st = st |> close() |> width_done() |> clear()
    exec(rest, move(st, st.x + dx, st.y + dy), ctx, d)
  end

  defp exec(<<22, rest::binary>>, st, ctx, d) do
    {args, st} = take_width(st, args(st), 1)
    [dx | _] = args ++ [0]
    st = st |> close() |> width_done() |> clear()
    exec(rest, move(st, st.x + dx, st.y), ctx, d)
  end

  defp exec(<<4, rest::binary>>, st, ctx, d) do
    {args, st} = take_width(st, args(st), 1)
    [dy | _] = args ++ [0]
    st = st |> close() |> width_done() |> clear()
    exec(rest, move(st, st.x, st.y + dy), ctx, d)
  end

  # lines
  defp exec(<<5, rest::binary>>, st, ctx, d),
    do: exec(rest, st |> rlines(args(st)) |> clear(), ctx, d)

  defp exec(<<6, rest::binary>>, st, ctx, d),
    do: exec(rest, st |> alt_lines(args(st), true) |> clear(), ctx, d)

  defp exec(<<7, rest::binary>>, st, ctx, d),
    do: exec(rest, st |> alt_lines(args(st), false) |> clear(), ctx, d)

  # curves
  defp exec(<<8, rest::binary>>, st, ctx, d),
    do: exec(rest, st |> rcurves(args(st)) |> clear(), ctx, d)

  defp exec(<<24, rest::binary>>, st, ctx, d) do
    a = args(st)
    {curves, line} = Enum.split(a, max(length(a) - 2, 0))
    exec(rest, st |> rcurves(curves) |> rlines(line) |> clear(), ctx, d)
  end

  defp exec(<<25, rest::binary>>, st, ctx, d) do
    a = args(st)
    {lines, curve} = Enum.split(a, max(length(a) - 6, 0))
    exec(rest, st |> rlines(lines) |> rcurves(curve) |> clear(), ctx, d)
  end

  defp exec(<<26, rest::binary>>, st, ctx, d) do
    {dx1, a} =
      if rem(length(args(st)), 2) == 1, do: {hd(args(st)), tl(args(st))}, else: {0, args(st)}

    exec(rest, st |> vv(a, dx1) |> clear(), ctx, d)
  end

  defp exec(<<27, rest::binary>>, st, ctx, d) do
    {dy1, a} =
      if rem(length(args(st)), 2) == 1, do: {hd(args(st)), tl(args(st))}, else: {0, args(st)}

    exec(rest, st |> hh(a, dy1) |> clear(), ctx, d)
  end

  defp exec(<<30, rest::binary>>, st, ctx, d),
    do: exec(rest, st |> alt_curves(args(st), false) |> clear(), ctx, d)

  defp exec(<<31, rest::binary>>, st, ctx, d),
    do: exec(rest, st |> alt_curves(args(st), true) |> clear(), ctx, d)

  # subroutines
  defp exec(<<op, rest::binary>>, %{stack: [i | stack]} = st, ctx, d) when op in [10, 29] do
    index = if op == 10, do: ctx.subrs, else: ctx.gsubrs
    sub = EmbedPdf.Font.CFF.index_get(index, trunc(i) + bias(index))
    st = %{st | stack: stack, ops: st.ops + 1}

    case sub do
      nil ->
        exec(rest, st, ctx, d)

      bin ->
        case exec(bin, st, ctx, d + 1) do
          {:return, st} -> exec(rest, st, ctx, d)
          {:eof, st} -> exec(rest, st, ctx, d)
          other -> other
        end
    end
  end

  defp exec(<<11, _rest::binary>>, st, _ctx, _d), do: {:return, st}

  # endchar
  defp exec(<<14, _rest::binary>>, st, ctx, _d) do
    a = args(st)

    {a, st} =
      if length(a) in [1, 5] and not st.width?, do: {tl(a), %{st | width: hd(a)}}, else: {a, st}

    st = st |> close() |> width_done() |> clear()

    case a do
      [adx, ady, bchar, achar] -> {:endchar, seac(st, ctx, adx, ady, trunc(bchar), trunc(achar))}
      _ -> {:endchar, st}
    end
  end

  # two-byte operators
  defp exec(<<12, op, rest::binary>>, st, ctx, d), do: exec(rest, escape(op, st), ctx, d)

  defp exec(<<_, rest::binary>>, st, ctx, d), do: exec(rest, clear(st), ctx, d)

  # ---------------------------------------------------------------- escape ops

  defp escape(35, st) do
    case args(st) do
      [dx1, dy1, dx2, dy2, dx3, dy3, dx4, dy4, dx5, dy5, dx6, dy6 | _] ->
        st
        |> curve(dx1, dy1, dx2, dy2, dx3, dy3)
        |> curve(dx4, dy4, dx5, dy5, dx6, dy6)
        |> clear()

      _ ->
        clear(st)
    end
  end

  defp escape(34, st) do
    case args(st) do
      [dx1, dx2, dy2, dx3, dx4, dx5, dx6 | _] ->
        st |> curve(dx1, 0, dx2, dy2, dx3, 0) |> curve(dx4, 0, dx5, -dy2, dx6, 0) |> clear()

      _ ->
        clear(st)
    end
  end

  defp escape(36, st) do
    case args(st) do
      [dx1, dy1, dx2, dy2, dx3, dx4, dx5, dy5, dx6 | _] ->
        st
        |> curve(dx1, dy1, dx2, dy2, dx3, 0)
        |> curve(dx4, 0, dx5, dy5, dx6, -(dy1 + dy2 + dy5))
        |> clear()

      _ ->
        clear(st)
    end
  end

  defp escape(37, st) do
    case args(st) do
      [dx1, dy1, dx2, dy2, dx3, dy3, dx4, dy4, dx5, dy5, d6 | _] ->
        dx = dx1 + dx2 + dx3 + dx4 + dx5
        dy = dy1 + dy2 + dy3 + dy4 + dy5
        {dx6, dy6} = if abs(dx) > abs(dy), do: {d6, -dy}, else: {-dx, d6}

        st
        |> curve(dx1, dy1, dx2, dy2, dx3, dy3)
        |> curve(dx4, dy4, dx5, dy5, dx6, dy6)
        |> clear()

      _ ->
        clear(st)
    end
  end

  defp escape(20, %{stack: [i, v | r]} = st),
    do: %{st | stack: r, trans: Map.put(st.trans, trunc(i), v), ops: st.ops + 1}

  defp escape(21, %{stack: [i | r]} = st),
    do: %{st | stack: [Map.get(st.trans, trunc(i), 0) | r], ops: st.ops + 1}

  defp escape(op, %{stack: s} = st) do
    stack =
      case {op, s} do
        {3, [b, a | r]} -> [bool(a != 0 and b != 0) | r]
        {4, [b, a | r]} -> [bool(a != 0 or b != 0) | r]
        {5, [a | r]} -> [bool(a == 0) | r]
        {9, [a | r]} -> [abs(a) | r]
        {10, [b, a | r]} -> [a + b | r]
        {11, [b, a | r]} -> [a - b | r]
        {12, [b, a | r]} -> [if(b == 0, do: 0, else: a / b) | r]
        {14, [a | r]} -> [-a | r]
        {15, [b, a | r]} -> [bool(a == b) | r]
        {18, [_ | r]} -> r
        {23, r} -> [:rand.uniform() | r]
        {24, [b, a | r]} -> [a * b | r]
        {26, [a | r]} -> [:math.sqrt(max(a, 0)) | r]
        {27, [a | r]} -> [a, a | r]
        {28, [b, a | r]} -> [a, b | r]
        {29, [i | r]} -> [Enum.at(r, max(trunc(i), 0), 0) | r]
        {22, [v2, v1, s2, s1 | r]} -> [if(v1 <= v2, do: s1, else: s2) | r]
        {30, [j, n | r]} -> roll(r, trunc(n), trunc(j))
        {0, _} -> []
        _ -> []
      end

    %{st | stack: stack, ops: st.ops + 1}
  end

  defp roll(r, n, j) when n > 0 and n <= length(r) do
    {top, rest} = Enum.split(r, n)
    items = Enum.reverse(top)
    k = Integer.mod(j, n)
    rolled = Enum.drop(items, n - k) ++ Enum.take(items, n - k)
    Enum.reverse(rolled) ++ rest
  end

  defp roll(r, _, _), do: r

  defp bool(true), do: 1
  defp bool(false), do: 0

  # ---------------------------------------------------------------- helpers

  defp push(st, v), do: %{st | stack: [v | st.stack]}
  defp args(st), do: Enum.reverse(st.stack)
  defp clear(st), do: %{st | stack: [], ops: st.ops + 1}
  defp width_done(st), do: %{st | width?: true}

  # drops the leading width operand when present, keeping it in the state
  defp take_width(%{width?: true} = st, args, _), do: {args, st}

  defp take_width(st, args, :even),
    do: if(rem(length(args), 2) == 1, do: {tl(args), %{st | width: hd(args)}}, else: {args, st})

  defp take_width(st, args, n),
    do: if(length(args) > n, do: {tl(args), %{st | width: hd(args)}}, else: {args, st})

  defp close(%{open?: true} = st), do: %{st | path: [:close | st.path], open?: false}
  defp close(st), do: st

  defp move(st, x, y), do: %{st | x: x, y: y, path: [{:move, x, y} | st.path], open?: true}

  defp line(st, x, y), do: %{st | x: x, y: y, path: [{:line, x, y} | st.path], open?: true}

  defp curve(st, dxa, dya, dxb, dyb, dxc, dyc) do
    x1 = st.x + dxa
    y1 = st.y + dya
    x2 = x1 + dxb
    y2 = y1 + dyb
    x3 = x2 + dxc
    y3 = y2 + dyc
    %{st | x: x3, y: y3, path: [{:curve, x1, y1, x2, y2, x3, y3} | st.path], open?: true}
  end

  defp rlines(st, [dx, dy | rest]), do: st |> line(st.x + dx, st.y + dy) |> rlines(rest)
  defp rlines(st, _), do: st

  defp alt_lines(st, [d | rest], true), do: st |> line(st.x + d, st.y) |> alt_lines(rest, false)
  defp alt_lines(st, [d | rest], false), do: st |> line(st.x, st.y + d) |> alt_lines(rest, true)
  defp alt_lines(st, [], _), do: st

  defp rcurves(st, [a, b, c, d, e, f | rest]), do: st |> curve(a, b, c, d, e, f) |> rcurves(rest)
  defp rcurves(st, _), do: st

  defp vv(st, [dya, dxb, dyb, dyc | rest], dx1),
    do: st |> curve(dx1, dya, dxb, dyb, 0, dyc) |> vv(rest, 0)

  defp vv(st, _, _), do: st

  defp hh(st, [dxa, dxb, dyb, dxc | rest], dy1),
    do: st |> curve(dxa, dy1, dxb, dyb, dxc, 0) |> hh(rest, 0)

  defp hh(st, _, _), do: st

  defp alt_curves(st, [d1, d2, d3, d4 | rest], horizontal?) do
    {last, rest} = if length(rest) == 1, do: {hd(rest), []}, else: {0, rest}

    st =
      if horizontal?,
        do: curve(st, d1, 0, d2, d3, last, d4),
        else: curve(st, 0, d1, d2, d3, d4, last)

    alt_curves(st, rest, not horizontal?)
  end

  defp alt_curves(st, _, _), do: st

  defp seac(st, ctx, adx, ady, bchar, achar) do
    base = ctx.seac.(bchar)
    accent = ctx.seac.(achar)

    base_path =
      case base && run_plain(base, ctx) do
        {:ok, cmds} -> cmds
        _ -> []
      end

    accent_path =
      case accent && run_plain(accent, ctx) do
        {:ok, cmds} -> EmbedPdf.Font.Outline.translate(cmds, adx, ady)
        _ -> []
      end

    %{st | path: Enum.reverse(base_path) ++ st.path, seac: accent_path}
  end

  defp run_plain(cs, ctx) do
    # nested seac is not allowed: give the inner run no seac
    run(cs, %{ctx | seac: fn _ -> nil end})
  end
end
