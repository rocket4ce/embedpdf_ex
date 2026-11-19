defmodule EmbedPdf.Font.Type1 do
  @moduledoc """
  Type 1 fonts (Adobe Type 1 Font Format): PFA/PFB/`FontFile` programs,
  eexec and charstring decryption, `Subrs`, `CharStrings`, the built-in
  `/Encoding` and `/FontMatrix`, with charstrings interpreted by
  `EmbedPdf.Font.Type1.Charstring` (flex and hint replacement through the
  standard OtherSubrs, `seac` accents).
  """

  import Bitwise

  alias EmbedPdf.Font.{Encoding, Outline}
  alias EmbedPdf.Font.Type1.Charstring

  defstruct charstrings: %{},
            subrs: {},
            matrix: [0.001, 0.0, 0.0, 0.001, 0.0, 0.0],
            encoding: nil,
            len_iv: 4

  @type t :: %__MODULE__{}

  @doc "Whether the bytes look like a Type 1 program (PFA or PFB)."
  def type1?(<<0x80, 1, _::binary>>), do: true
  def type1?(<<"%!PS-AdobeFont", _::binary>>), do: true
  def type1?(<<"%!FontType1", _::binary>>), do: true
  def type1?(data) when is_binary(data), do: :binary.match(data, "eexec") != :nomatch
  def type1?(_), do: false

  @doc "Parses a Type 1 font program."
  @spec parse(binary()) :: {:ok, t()} | :error
  def parse(data) when is_binary(data) do
    data = strip_pfb(data)

    case :binary.match(data, "eexec") do
      {pos, 5} ->
        clear = binary_part(data, 0, pos)
        encrypted = data |> binary_part(pos + 5, byte_size(data) - pos - 5) |> skip_eexec_ws()
        encrypted = if hex_start?(encrypted), do: hex_decode(encrypted), else: encrypted
        private = decrypt(encrypted, 55665) |> drop(4)

        len_iv =
          case Regex.run(~r{/lenIV\s+(-?\d+)}, private) do
            [_, n] -> String.to_integer(n)
            _ -> 4
          end

        {subrs, subrs_end} = parse_subrs(private, len_iv)
        charstrings = parse_charstrings(private, subrs_end)

        if map_size(charstrings) == 0 do
          :error
        else
          {:ok,
           %__MODULE__{
             charstrings: charstrings,
             subrs: subrs,
             matrix: font_matrix(clear),
             encoding: parse_encoding(clear),
             len_iv: len_iv
           }}
        end

      :nomatch ->
        :error
    end
  rescue
    _ -> :error
  end

  def parse(_), do: :error

  # ---------------------------------------------------------------- container

  defp strip_pfb(<<0x80, _::binary>> = data), do: pfb_segments(data, [])
  defp strip_pfb(data), do: data

  defp pfb_segments(<<0x80, type, len::little-32, rest::binary>>, acc) when type in [1, 2] do
    len = min(len, byte_size(rest))
    <<seg::binary-size(len), rest::binary>> = rest
    pfb_segments(rest, [seg | acc])
  end

  defp pfb_segments(_, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp skip_eexec_ws(<<c, rest::binary>>) when c in [?\r, ?\n, ?\t, ?\s], do: skip_eexec_ws(rest)
  defp skip_eexec_ws(rest), do: rest

  defp hex_start?(<<a, b, c, d, _::binary>>), do: Enum.all?([a, b, c, d], &hex?/1)
  defp hex_start?(_), do: false

  defp hex?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  defp hex_decode(data) do
    digits =
      for <<c <- data>>, hex?(c) or c in [?\r, ?\n, ?\t, ?\s], hex?(c), into: <<>>, do: <<c>>

    digits = if rem(byte_size(digits), 2) == 1, do: digits <> "0", else: digits
    Base.decode16!(digits, case: :mixed)
  end

  @doc "Type 1 decryption (`r` = 55665 for eexec, 4330 for charstrings)."
  @spec decrypt(binary(), non_neg_integer()) :: binary()
  def decrypt(data, r), do: do_decrypt(data, r, [])

  defp do_decrypt(<<c, rest::binary>>, r, acc) do
    p = bxor(c, r >>> 8)
    do_decrypt(rest, band((c + r) * 52845 + 22719, 0xFFFF), [p | acc])
  end

  defp do_decrypt(<<>>, _r, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  defp drop(bin, n) when n >= 0 and byte_size(bin) >= n,
    do: binary_part(bin, n, byte_size(bin) - n)

  defp drop(bin, n) when n < 0, do: bin
  defp drop(_bin, _n), do: <<>>

  # ---------------------------------------------------------------- cleartext

  defp font_matrix(clear) do
    case Regex.run(~r{/FontMatrix\s*[\[\{]([^\]\}]*)[\]\}]}, clear) do
      [_, nums] ->
        values =
          nums
          |> String.split(~r/\s+/, trim: true)
          |> Enum.map(&parse_num/1)

        if length(values) == 6 and Enum.all?(values, &is_number/1) and Enum.at(values, 0) != 0,
          do: Enum.map(values, &(&1 / 1)),
          else: [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]

      _ ->
        [0.001, 0.0, 0.0, 0.001, 0.0, 0.0]
    end
  end

  defp parse_num(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_encoding(clear) do
    cond do
      Regex.match?(~r{/Encoding\s+StandardEncoding\s+def}, clear) ->
        Encoding.named("StandardEncoding")

      true ->
        case Regex.scan(~r{dup\s+(\d+)\s*/([^\s/\[\]\(\)\{\}<>]+)\s+put}, clear) do
          [] ->
            nil

          entries ->
            Map.new(entries, fn [_, code, name] -> {String.to_integer(code), name} end)
        end
    end
  end

  # ---------------------------------------------------------------- private dictionary

  defp parse_subrs(private, len_iv) do
    case :binary.match(private, "/Subrs") do
      {pos, len} ->
        rest = binary_part(private, pos + len, byte_size(private) - pos - len)

        case next_int(rest) do
          {count, rest} when count >= 0 and count < 65536 ->
            {entries, rest} = subr_entries(rest, len_iv, %{})
            subrs = for i <- 0..(count - 1)//1, do: Map.get(entries, i, <<>>)
            {List.to_tuple(subrs), byte_size(private) - byte_size(rest)}

          _ ->
            {{}, 0}
        end

      :nomatch ->
        {{}, 0}
    end
  end

  defp subr_entries(input, len_iv, acc) do
    with {"dup", rest} <- next_token(skip_to_dup(input)),
         {idx, rest} when is_integer(idx) <- next_int(rest),
         {len, rest} when is_integer(len) and len >= 0 <- next_int(rest),
         {_rd, rest} <- next_token(rest),
         <<_space, rest::binary>> <- rest,
         true <- byte_size(rest) >= len do
      <<bytes::binary-size(len), rest::binary>> = rest
      subr_entries(rest, len_iv, Map.put(acc, idx, decrypt_charstring(bytes, len_iv)))
    else
      _ -> {acc, input}
    end
  end

  # skips trailing tokens of an entry (NP, |, noaccess put, array) up to the next dup
  defp skip_to_dup(input) do
    rest = skip_ws(input)

    case next_token(rest) do
      {"dup", _} ->
        rest

      {tok, r} when tok in ["NP", "|", "noaccess", "put", "array", "readonly", "executeonly"] ->
        skip_to_dup(r)

      _ ->
        rest
    end
  end

  defp parse_charstrings(private, from) do
    region = binary_part(private, from, byte_size(private) - from)

    {region, base} =
      case :binary.match(region, "/CharStrings") do
        {pos, len} -> {region, pos + len}
        :nomatch -> {private, match_end(private, "/CharStrings") || byte_size(private)}
      end

    rest = binary_part(region, base, byte_size(region) - base)

    case next_int(rest) do
      {_count, rest} -> charstring_entries(rest, %{})
      _ -> %{}
    end
  end

  defp match_end(bin, pat) do
    case :binary.match(bin, pat) do
      {p, l} -> p + l
      :nomatch -> nil
    end
  end

  defp charstring_entries(input, acc) do
    rest = skip_ws(input)

    case rest do
      <<"/", _::binary>> ->
        with {"/" <> name, rest} <- next_token(rest),
             {len, rest} when is_integer(len) and len >= 0 <- next_int(rest),
             {_rd, rest} <- next_token(rest),
             <<_space, rest::binary>> <- rest,
             true <- byte_size(rest) >= len do
          <<bytes::binary-size(len), rest::binary>> = rest
          charstring_entries(rest, Map.put(acc, name, bytes))
        else
          _ -> acc
        end

      <<>> ->
        acc

      _ ->
        case next_token(rest) do
          {"end", _} -> acc
          {"", _} -> acc
          {_tok, r} -> charstring_entries(r, acc)
        end
    end
  end

  defp skip_ws(<<c, rest::binary>>) when c in [?\r, ?\n, ?\t, ?\s, 0, 12], do: skip_ws(rest)
  defp skip_ws(rest), do: rest

  defp next_token(input) do
    rest = skip_ws(input)
    take_token(rest, [])
  end

  defp take_token(<<c, rest::binary>>, acc) when c not in [?\r, ?\n, ?\t, ?\s, 0, 12],
    do: take_token(rest, [c | acc])

  defp take_token(rest, acc), do: {acc |> Enum.reverse() |> :erlang.list_to_binary(), rest}

  defp next_int(input) do
    {tok, rest} = next_token(input)

    case Integer.parse(tok) do
      {n, ""} -> {n, rest}
      _ -> :error
    end
  end

  defp decrypt_charstring(bytes, len_iv) when len_iv < 0, do: bytes
  defp decrypt_charstring(bytes, len_iv), do: bytes |> decrypt(4330) |> drop(len_iv)

  # ---------------------------------------------------------------- glyphs

  @doc "Whether the font has a glyph named `name`."
  def has_glyph?(%__MODULE__{charstrings: cs}, name), do: Map.has_key?(cs, name)

  @doc """
  The outline of glyph `name` in text space for size 1 (FontMatrix
  applied), or nil when the font has no such glyph.
  """
  @spec glyph(t(), String.t()) :: [Outline.cmd()] | nil
  def glyph(%__MODULE__{} = t1, name) when is_binary(name) do
    case Map.fetch(t1.charstrings, name) do
      {:ok, encrypted} ->
        cs = decrypt_charstring(encrypted, t1.len_iv)

        ctx = %{
          subrs: t1.subrs,
          seac: fn code ->
            case Map.get(Encoding.named("StandardEncoding"), code) do
              nil ->
                nil

              n ->
                t1.charstrings |> Map.get(n) |> then(&(&1 && decrypt_charstring(&1, t1.len_iv)))
            end
          end
        }

        case Charstring.run(cs, ctx) do
          {:ok, cmds} -> Outline.transform(cmds, t1.matrix)
          :error -> nil
        end

      :error ->
        nil
    end
  rescue
    _ -> nil
  end

  def glyph(_, _), do: nil

  @doc """
  The advance width of glyph `name` in text space for size 1, read from the
  `hsbw`/`sbw` that opens its charstring, or nil.
  """
  @spec advance(t(), String.t()) :: float() | nil
  def advance(%__MODULE__{} = t1, name) when is_binary(name) do
    with {:ok, encrypted} <- Map.fetch(t1.charstrings, name),
         wx when is_number(wx) <- side_bearing_width(decrypt_charstring(encrypted, t1.len_iv), []) do
      [a | _] = t1.matrix
      wx * a
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def advance(_, _), do: nil

  # numbers up to the first operator, which is `hsbw` (sbx wx) or `sbw`
  # (sbx sby wx wy) in a well-formed charstring; `div` may build an operand
  defp side_bearing_width(<<13, _::binary>>, [wx, _sbx | _]), do: wx
  defp side_bearing_width(<<12, 7, _::binary>>, [_wy, wx, _sby, _sbx | _]), do: wx

  defp side_bearing_width(<<12, 12, rest::binary>>, [b, a | stack]) when b != 0,
    do: side_bearing_width(rest, [a / b | stack])

  defp side_bearing_width(<<255, v::signed-32, rest::binary>>, stack),
    do: side_bearing_width(rest, [v | stack])

  defp side_bearing_width(<<b, b1, rest::binary>>, stack) when b in 247..250,
    do: side_bearing_width(rest, [(b - 247) * 256 + b1 + 108 | stack])

  defp side_bearing_width(<<b, b1, rest::binary>>, stack) when b in 251..254,
    do: side_bearing_width(rest, [-(b - 251) * 256 - b1 - 108 | stack])

  defp side_bearing_width(<<b, rest::binary>>, stack) when b in 32..246,
    do: side_bearing_width(rest, [b - 139 | stack])

  defp side_bearing_width(_, _), do: nil
end

defmodule EmbedPdf.Font.Type1.Charstring do
  @moduledoc "Type 1 charstring interpreter: outlines in charstring units, hints ignored."

  @max_ops 100_000

  @doc """
  Runs a decrypted charstring. `ctx` has `:subrs` (tuple of decrypted
  subroutines) and `:seac` (StandardEncoding code → decrypted charstring).
  """
  @spec run(binary(), map()) :: {:ok, list()} | :error
  def run(cs, ctx) do
    case exec(cs, new_state(), ctx, 0) do
      {:error, _} -> :error
      {_, st} -> {:ok, finish(st)}
    end
  rescue
    _ -> :error
  end

  defp new_state,
    do: %{
      x: 0.0,
      y: 0.0,
      sbx: 0.0,
      stack: [],
      ps: [],
      path: [],
      open?: false,
      flex: nil,
      ops: 0,
      accent: []
    }

  defp finish(st) do
    st = close(st)
    Enum.reverse(st.path) ++ st.accent
  end

  defp exec(_cs, %{ops: n} = st, _ctx, _d) when n > @max_ops, do: {:error, st}
  defp exec(_cs, st, _ctx, d) when d > 12, do: {:error, st}
  defp exec(<<>>, st, _ctx, _d), do: {:eof, st}

  defp exec(<<255, v::signed-32, rest::binary>>, st, ctx, d), do: exec(rest, push(st, v), ctx, d)

  defp exec(<<b, rest::binary>>, st, ctx, d) when b in 32..246,
    do: exec(rest, push(st, b - 139), ctx, d)

  defp exec(<<b, w, rest::binary>>, st, ctx, d) when b in 247..250,
    do: exec(rest, push(st, (b - 247) * 256 + w + 108), ctx, d)

  defp exec(<<b, w, rest::binary>>, st, ctx, d) when b in 251..254,
    do: exec(rest, push(st, -(b - 251) * 256 - w - 108), ctx, d)

  # hsbw: sbx wx
  defp exec(<<13, rest::binary>>, st, ctx, d) do
    [sbx | _] = args(st) ++ [0]
    exec(rest, %{clear(st) | x: sbx / 1, y: 0.0, sbx: sbx / 1}, ctx, d)
  end

  defp exec(<<op, rest::binary>>, st, ctx, d) when op in [1, 3], do: exec(rest, clear(st), ctx, d)

  defp exec(<<21, rest::binary>>, st, ctx, d) do
    [dx, dy | _] = args(st) ++ [0, 0]
    exec(rest, st |> clear() |> rmove(dx, dy), ctx, d)
  end

  defp exec(<<22, rest::binary>>, st, ctx, d) do
    [dx | _] = args(st) ++ [0]
    exec(rest, st |> clear() |> rmove(dx, 0), ctx, d)
  end

  defp exec(<<4, rest::binary>>, st, ctx, d) do
    [dy | _] = args(st) ++ [0]
    exec(rest, st |> clear() |> rmove(0, dy), ctx, d)
  end

  defp exec(<<5, rest::binary>>, st, ctx, d) do
    [dx, dy | _] = args(st) ++ [0, 0]
    exec(rest, st |> clear() |> line(st.x + dx, st.y + dy), ctx, d)
  end

  defp exec(<<6, rest::binary>>, st, ctx, d) do
    [dx | _] = args(st) ++ [0]
    exec(rest, st |> clear() |> line(st.x + dx, st.y), ctx, d)
  end

  defp exec(<<7, rest::binary>>, st, ctx, d) do
    [dy | _] = args(st) ++ [0]
    exec(rest, st |> clear() |> line(st.x, st.y + dy), ctx, d)
  end

  defp exec(<<8, rest::binary>>, st, ctx, d) do
    case args(st) do
      [a, b, c, e, f, g | _] -> exec(rest, st |> clear() |> curve(a, b, c, e, f, g), ctx, d)
      _ -> exec(rest, clear(st), ctx, d)
    end
  end

  defp exec(<<30, rest::binary>>, st, ctx, d) do
    case args(st) do
      [dy1, dx2, dy2, dx3 | _] ->
        exec(rest, st |> clear() |> curve(0, dy1, dx2, dy2, dx3, 0), ctx, d)

      _ ->
        exec(rest, clear(st), ctx, d)
    end
  end

  defp exec(<<31, rest::binary>>, st, ctx, d) do
    case args(st) do
      [dx1, dx2, dy2, dy3 | _] ->
        exec(rest, st |> clear() |> curve(dx1, 0, dx2, dy2, 0, dy3), ctx, d)

      _ ->
        exec(rest, clear(st), ctx, d)
    end
  end

  defp exec(<<9, rest::binary>>, st, ctx, d), do: exec(rest, st |> clear() |> close(), ctx, d)

  defp exec(<<10, rest::binary>>, %{stack: [i | stack]} = st, ctx, d) do
    st = %{st | stack: stack, ops: st.ops + 1}
    i = trunc(i)

    if i >= 0 and i < tuple_size(ctx.subrs) do
      case exec(elem(ctx.subrs, i), st, ctx, d + 1) do
        {:return, st} -> exec(rest, st, ctx, d)
        {:eof, st} -> exec(rest, st, ctx, d)
        other -> other
      end
    else
      exec(rest, st, ctx, d)
    end
  end

  defp exec(<<11, _::binary>>, st, _ctx, _d), do: {:return, st}
  defp exec(<<14, _::binary>>, st, _ctx, _d), do: {:endchar, st |> clear() |> close()}

  defp exec(<<12, op, rest::binary>>, st, ctx, d) do
    case escape(op, st, ctx) do
      {:endchar, st} -> {:endchar, st}
      st -> exec(rest, st, ctx, d)
    end
  end

  defp exec(<<_, rest::binary>>, st, ctx, d), do: exec(rest, clear(st), ctx, d)

  # ---------------------------------------------------------------- escapes

  # sbw: sbx sby wx wy
  defp escape(7, st, _ctx) do
    [sbx, sby | _] = args(st) ++ [0, 0]
    %{clear(st) | x: sbx / 1, y: sby / 1, sbx: sbx / 1}
  end

  # div
  defp escape(12, %{stack: [b, a | r]} = st, _ctx),
    do: %{st | stack: [if(b == 0, do: 0, else: a / b) | r], ops: st.ops + 1}

  # callothersubr: arg1 ... argn n othersubr#
  defp escape(16, %{stack: [k, n | r]} = st, _ctx) do
    n = max(trunc(n), 0)
    {args_rev, r} = Enum.split(r, n)
    args = Enum.reverse(args_rev)
    st = %{st | stack: r, ops: st.ops + 1}

    case trunc(k) do
      1 ->
        %{st | flex: []}

      2 ->
        st

      0 ->
        st = end_flex(st)

        case args do
          [_fh, x, y | _] -> %{st | ps: [x, y]}
          _ -> %{st | ps: [st.x, st.y]}
        end

      3 ->
        %{st | ps: [3]}

      _ ->
        %{st | ps: args}
    end
  end

  # pop: moves a value from the PostScript stack
  defp escape(17, %{ps: [v | ps]} = st, _ctx),
    do: %{st | ps: ps, stack: [v | st.stack], ops: st.ops + 1}

  defp escape(17, st, _ctx), do: %{st | stack: [0 | st.stack], ops: st.ops + 1}

  # setcurrentpoint
  defp escape(33, st, _ctx) do
    case args(st) do
      [x, y | _] -> %{clear(st) | x: x / 1, y: y / 1}
      _ -> clear(st)
    end
  end

  # seac: asb adx ady bchar achar
  defp escape(6, st, ctx) do
    case args(st) do
      [asb, adx, ady, bchar, achar | _] ->
        base = run_part(ctx.seac.(trunc(bchar)), ctx)
        accent = run_part(ctx.seac.(trunc(achar)), ctx)
        accent = EmbedPdf.Font.Outline.translate(accent, adx + st.sbx - asb, ady)
        st = st |> clear() |> close()
        {:endchar, %{st | path: Enum.reverse(base) ++ st.path, accent: accent}}

      _ ->
        clear(st)
    end
  end

  defp escape(_op, st, _ctx), do: clear(st)

  defp run_part(nil, _ctx), do: []

  defp run_part(cs, ctx) do
    case run(cs, %{ctx | seac: fn _ -> nil end}) do
      {:ok, cmds} -> cmds
      :error -> []
    end
  end

  # ---------------------------------------------------------------- helpers

  defp push(st, v), do: %{st | stack: [v | st.stack]}
  defp args(st), do: Enum.reverse(st.stack)
  defp clear(st), do: %{st | stack: [], ops: st.ops + 1}

  defp close(%{open?: true} = st), do: %{st | path: [:close | st.path], open?: false}
  defp close(st), do: st

  defp rmove(%{flex: points} = st, dx, dy) when is_list(points) do
    x = st.x + dx
    y = st.y + dy
    %{st | x: x, y: y, flex: [{x, y} | points]}
  end

  defp rmove(st, dx, dy) do
    st = close(st)
    x = st.x + dx
    y = st.y + dy
    %{st | x: x, y: y, path: [{:move, x, y} | st.path], open?: true}
  end

  defp end_flex(%{flex: points} = st) when is_list(points) do
    case Enum.reverse(points) do
      [_ref, {x1, y1}, {x2, y2}, {x3, y3}, {x4, y4}, {x5, y5}, {x6, y6} | _] ->
        path = [{:curve, x4, y4, x5, y5, x6, y6}, {:curve, x1, y1, x2, y2, x3, y3} | st.path]
        %{st | flex: nil, path: path, x: x6, y: y6, open?: true}

      _ ->
        %{st | flex: nil}
    end
  end

  defp end_flex(st), do: st

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
end
