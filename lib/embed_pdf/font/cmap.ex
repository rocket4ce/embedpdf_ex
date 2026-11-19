defmodule EmbedPdf.Font.CMap do
  @moduledoc """
  CMaps: character codes → CIDs (encodings of Type 0 fonts) and character
  codes → Unicode (`/ToUnicode`). Parses embedded CMap streams and the
  predefined Adobe CMaps shipped in `priv/cmap`.
  """

  alias EmbedPdf.PDF.Parser

  defstruct name: nil,
            wmode: 0,
            # [{n_bytes, low, high}]
            codespace: [],
            cid_single: %{},
            # tuple of {low, high, n_bytes, start} sorted by low
            cid_ranges: {},
            uni_single: %{},
            # tuple of {low, high, n_bytes, start_value} where start_value is a binary (UTF-16BE) or list
            uni_ranges: {}

  @type t :: %__MODULE__{}

  @cmap_dir Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "cmap"]))

  @doc "An Identity-H / Identity-V CMap."
  def identity(wmode \\ 0),
    do: %__MODULE__{
      name: if(wmode == 1, do: "Identity-V", else: "Identity-H"),
      wmode: wmode,
      codespace: [{2, 0, 0xFFFF}],
      cid_ranges: {{0, 0xFFFF, 2, 0}}
    }

  @doc "Loads a predefined CMap by name (cached), or nil."
  @spec predefined(String.t()) :: t() | nil
  def predefined("Identity-H"), do: identity(0)
  def predefined("Identity-V"), do: identity(1)

  def predefined(name) when is_binary(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, :missing) do
      :missing ->
        path = Path.join(@cmap_dir, name)

        value =
          if not String.contains?(name, ["/", ".."]) and File.regular?(path),
            do: path |> File.read!() |> parse(),
            else: nil

        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  def predefined(_), do: nil

  @doc "Parses CMap program text."
  @spec parse(binary(), (String.t() -> t() | nil)) :: t()
  def parse(data, usecmap \\ &predefined/1) do
    tokens = tokenize(data, [])

    acc = %{
      name: nil,
      wmode: 0,
      codespace: [],
      cid_single: %{},
      cid_ranges: [],
      uni_single: %{},
      uni_ranges: [],
      base: nil
    }

    acc = walk(tokens, acc, usecmap)
    base = acc.base

    cmap = %__MODULE__{
      name: acc.name,
      wmode: acc.wmode,
      codespace: Enum.reverse(acc.codespace),
      cid_single: acc.cid_single,
      cid_ranges: acc.cid_ranges |> Enum.sort() |> List.to_tuple(),
      uni_single: acc.uni_single,
      uni_ranges: acc.uni_ranges |> Enum.sort() |> List.to_tuple()
    }

    if base, do: merge(base, cmap), else: cmap
  end

  defp merge(base, cmap) do
    %{
      cmap
      | codespace:
          if(cmap.codespace == [], do: base.codespace, else: cmap.codespace ++ base.codespace),
        cid_single: Map.merge(base.cid_single, cmap.cid_single),
        cid_ranges:
          (Tuple.to_list(base.cid_ranges) ++ Tuple.to_list(cmap.cid_ranges))
          |> Enum.sort()
          |> List.to_tuple(),
        uni_single: Map.merge(base.uni_single, cmap.uni_single),
        uni_ranges:
          (Tuple.to_list(base.uni_ranges) ++ Tuple.to_list(cmap.uni_ranges))
          |> Enum.sort()
          |> List.to_tuple(),
        wmode: if(cmap.wmode == 0, do: base.wmode, else: cmap.wmode)
    }
  end

  defp tokenize(data, acc) do
    case Parser.parse_value(data, refs: false) do
      :eof -> Enum.reverse(acc)
      {value, rest} -> tokenize(rest, [value | acc])
    end
  end

  defp walk([], acc, _), do: acc

  defp walk([{:keyword, "begincodespacerange"} | rest], acc, u) do
    {items, rest} = take_until(rest, "endcodespacerange")

    ranges =
      items
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.flat_map(fn
        [{:string, lo}, {:string, hi}] -> [{byte_size(lo), int(lo), int(hi)}]
        _ -> []
      end)

    walk(rest, %{acc | codespace: Enum.reverse(ranges) ++ acc.codespace}, u)
  end

  defp walk([{:keyword, "begincidrange"} | rest], acc, u) do
    {items, rest} = take_until(rest, "endcidrange")

    ranges =
      items
      |> Enum.chunk_every(3, 3, :discard)
      |> Enum.flat_map(fn
        [{:string, lo}, {:string, hi}, cid] when is_integer(cid) ->
          [{int(lo), int(hi), byte_size(lo), cid}]

        _ ->
          []
      end)

    walk(rest, %{acc | cid_ranges: ranges ++ acc.cid_ranges}, u)
  end

  defp walk([{:keyword, "begincidchar"} | rest], acc, u) do
    {items, rest} = take_until(rest, "endcidchar")

    singles =
      items
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.reduce(acc.cid_single, fn
        [{:string, code}, cid], m when is_integer(cid) ->
          Map.put(m, {byte_size(code), int(code)}, cid)

        _, m ->
          m
      end)

    walk(rest, %{acc | cid_single: singles}, u)
  end

  defp walk([{:keyword, "beginbfchar"} | rest], acc, u) do
    {items, rest} = take_until(rest, "endbfchar")

    singles =
      items
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.reduce(acc.uni_single, fn
        [{:string, code}, {:string, dst}], m ->
          Map.put(m, {byte_size(code), int(code)}, utf16(dst))

        [{:string, code}, name], m when is_binary(name) ->
          Map.put(m, {byte_size(code), int(code)}, EmbedPdf.Font.GlyphList.to_unicode(name) || "")

        _, m ->
          m
      end)

    walk(rest, %{acc | uni_single: singles}, u)
  end

  defp walk([{:keyword, "beginbfrange"} | rest], acc, u) do
    {items, rest} = take_until(rest, "endbfrange")

    {singles, ranges} =
      items
      |> Enum.chunk_every(3, 3, :discard)
      |> Enum.reduce({acc.uni_single, acc.uni_ranges}, fn
        [{:string, lo}, {:string, hi}, {:string, dst}], {s, r} ->
          {s, [{int(lo), int(hi), byte_size(lo), dst} | r]}

        [{:string, lo}, {:string, hi}, list], {s, r} when is_list(list) ->
          n = byte_size(lo)
          lo_i = int(lo)

          s =
            list
            |> Enum.with_index()
            |> Enum.reduce(s, fn
              {{:string, dst}, i}, s ->
                if lo_i + i <= int(hi), do: Map.put(s, {n, lo_i + i}, utf16(dst)), else: s

              _, s ->
                s
            end)

          {s, r}

        _, acc2 ->
          acc2
      end)

    walk(rest, %{acc | uni_single: singles, uni_ranges: ranges}, u)
  end

  defp walk([name, {:keyword, "usecmap"} | rest], acc, u) when is_binary(name) do
    walk(rest, %{acc | base: u.(name)}, u)
  end

  defp walk(["CMapName", name | rest], acc, u) when is_binary(name),
    do: walk(rest, %{acc | name: name}, u)

  defp walk(["WMode", w | rest], acc, u) when is_integer(w), do: walk(rest, %{acc | wmode: w}, u)
  defp walk([_ | rest], acc, u), do: walk(rest, acc, u)

  defp take_until(tokens, kw) do
    {items, rest} = Enum.split_while(tokens, &(&1 != {:keyword, kw}))
    {items, Enum.drop(rest, 1)}
  end

  defp int(bin), do: :binary.decode_unsigned(bin)

  defp utf16(<<>>), do: ""

  defp utf16(dst) do
    dst = if rem(byte_size(dst), 2) == 1, do: <<0>> <> dst, else: dst

    case :unicode.characters_to_binary(dst, {:utf16, :big}) do
      s when is_binary(s) -> s
      _ -> for(<<cp::16 <- dst>>, cp not in 0xD800..0xDFFF, into: "", do: <<cp::utf8>>)
    end
  end

  # ---------------------------------------------------------------- lookups

  @doc """
  Splits a string into character codes per the codespace ranges.
  Returns `[{code, n_bytes}]`.
  """
  @spec codes(t(), binary()) :: [{non_neg_integer(), pos_integer()}]
  def codes(%__MODULE__{codespace: []}, data),
    do: for(<<a, b <- pad_even(data)>>, do: {a * 256 + b, 2})

  def codes(cmap, data), do: split(cmap.codespace, data, [])

  defp pad_even(d) when rem(byte_size(d), 2) == 1, do: d <> <<0>>
  defp pad_even(d), do: d

  defp split(_cs, <<>>, acc), do: Enum.reverse(acc)

  defp split(cs, data, acc) do
    case match_codespace(cs, data, 1) do
      {code, n} ->
        split(cs, binary_part(data, n, byte_size(data) - n), [{code, n} | acc])

      nil ->
        # no range matches: take the shortest length that exists
        n = cs |> Enum.map(&elem(&1, 0)) |> Enum.min() |> min(byte_size(data))
        <<code::size(n)-unit(8), rest::binary>> = data
        split(cs, rest, [{code, n} | acc])
    end
  end

  defp match_codespace(_cs, _data, n) when n > 4, do: nil

  defp match_codespace(cs, data, n) do
    if byte_size(data) >= n do
      <<code::size(n)-unit(8), _::binary>> = data

      if Enum.any?(cs, fn {len, lo, hi} -> len == n and code >= lo and code <= hi end),
        do: {code, n},
        else: match_codespace(cs, data, n + 1)
    else
      nil
    end
  end

  @doc "Maps a code to a CID (0 when unmapped)."
  @spec cid(t(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  def cid(cmap, code, n) do
    case Map.fetch(cmap.cid_single, {n, code}) do
      {:ok, cid} ->
        cid

      :error ->
        case find_range(cmap.cid_ranges, code, n) do
          {lo, _hi, _n, start} -> start + (code - lo)
          nil -> 0
        end
    end
  end

  @doc "Maps a code to Unicode text, or nil."
  @spec unicode(t(), non_neg_integer(), pos_integer()) :: String.t() | nil
  def unicode(cmap, code, n) do
    case Map.fetch(cmap.uni_single, {n, code}) do
      {:ok, s} ->
        s

      :error ->
        # a ToUnicode CMap may declare codes with a different length than the font uses
        case Enum.find_value([n, 1, 2], fn len -> Map.get(cmap.uni_single, {len, code}) end) do
          nil ->
            case find_range(cmap.uni_ranges, code, n) || find_range(cmap.uni_ranges, code, nil) do
              {lo, _hi, _n, dst} -> range_value(dst, code - lo)
              nil -> nil
            end

          s ->
            s
        end
    end
  end

  defp range_value(dst, offset) when byte_size(dst) >= 1 do
    size = byte_size(dst)
    <<prefix::binary-size(size - 1), last>> = dst
    total = last + offset

    bytes =
      if total > 255 and size >= 2 do
        <<p2::binary-size(size - 2), hi, _>> = dst
        p2 <> <<hi + div(total, 256), rem(total, 256)>>
      else
        prefix <> <<rem(total, 256)>>
      end

    utf16(bytes)
  end

  defp range_value(_, _), do: nil

  # binary search over sorted {lo, hi, n, value} tuples
  defp find_range({}, _code, _n), do: nil

  defp find_range(ranges, code, n) do
    idx = bsearch(ranges, code, 0, tuple_size(ranges) - 1, -1)
    scan_back(ranges, idx, code, n, 0)
  end

  defp bsearch(_r, _code, lo, hi, best) when lo > hi, do: best

  defp bsearch(r, code, lo, hi, best) do
    mid = div(lo + hi, 2)
    {rlo, _, _, _} = elem(r, mid)

    if rlo <= code,
      do: bsearch(r, code, mid + 1, hi, mid),
      else: bsearch(r, code, lo, mid - 1, best)
  end

  # ranges may overlap: look back a little for one that covers the code
  defp scan_back(_r, idx, _code, _n, steps) when idx < 0 or steps > 64, do: nil

  defp scan_back(r, idx, code, n, steps) do
    {lo, hi, len, _} = range = elem(r, idx)

    if code >= lo and code <= hi and (n == nil or len == n),
      do: range,
      else: scan_back(r, idx - 1, code, n, steps + 1)
  end
end
