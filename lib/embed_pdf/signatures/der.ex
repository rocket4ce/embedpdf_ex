defmodule EmbedPdf.Signatures.DER do
  @moduledoc """
  A small DER reader and writer for the CMS structures in PDF signatures.

  Decoding keeps every element's exact bytes (`raw`), because CMS signs
  the DER of the signed attributes as they were written, not a
  re-encoding of them.

  A decoded element is `%{class, constructed?, tag, value, raw}` where
  `value` is a list of children for constructed elements and the content
  bytes otherwise.
  """

  import Bitwise

  @type element :: %{
          class: :universal | :application | :context | :private,
          constructed?: boolean(),
          tag: non_neg_integer(),
          value: binary() | [element()],
          raw: binary()
        }

  # ---------------------------------------------------------------- decoding

  @doc "Decodes the first element of `data` (trailing bytes, like the zero padding of /Contents, are ignored)."
  @spec decode(binary()) :: {:ok, element()} | :error
  def decode(data) do
    case element(data, 0) do
      {:ok, el, _rest} -> {:ok, el}
      :error -> :error
    end
  rescue
    _ -> :error
  end

  defp element(<<id, rest::binary>> = all, depth) when depth < 64 do
    class =
      case id >>> 6 do
        0 -> :universal
        1 -> :application
        2 -> :context
        3 -> :private
      end

    constructed? = (id &&& 0x20) != 0

    with {:ok, tag, rest} <- tag_number(id &&& 0x1F, rest),
         {:ok, len, rest} <- read_length(rest),
         true <- byte_size(rest) >= len do
      header = byte_size(all) - byte_size(rest)
      <<content::binary-size(len), after_el::binary>> = rest
      raw = binary_part(all, 0, header + len)

      value =
        if constructed? do
          children(content, depth + 1, [])
        else
          content
        end

      case value do
        :error ->
          :error

        v ->
          {:ok, %{class: class, constructed?: constructed?, tag: tag, value: v, raw: raw},
           after_el}
      end
    else
      _ -> :error
    end
  end

  defp element(_, _), do: :error

  defp children(<<>>, _depth, acc), do: Enum.reverse(acc)

  defp children(data, depth, acc) do
    case element(data, depth) do
      {:ok, el, rest} -> children(rest, depth, [el | acc])
      :error -> :error
    end
  end

  defp tag_number(31, rest), do: long_tag(rest, 0)
  defp tag_number(n, rest), do: {:ok, n, rest}

  defp long_tag(<<1::1, b::7, rest::binary>>, acc), do: long_tag(rest, acc <<< 7 ||| b)
  defp long_tag(<<0::1, b::7, rest::binary>>, acc), do: {:ok, acc <<< 7 ||| b, rest}
  defp long_tag(_, _), do: :error

  defp read_length(<<0::1, n::7, rest::binary>>), do: {:ok, n, rest}

  defp read_length(<<1::1, k::7, rest::binary>>) when k > 0 and k <= 4 and byte_size(rest) >= k do
    <<n::size(k)-unit(8), rest::binary>> = rest
    {:ok, n, rest}
  end

  defp read_length(_), do: :error

  # ---------------------------------------------------------------- reading helpers

  @doc "Children of a constructed element (empty list otherwise)."
  def children(%{value: v}) when is_list(v), do: v
  def children(_), do: []

  @doc "The OID tuple of an OBJECT IDENTIFIER element."
  def oid(%{class: :universal, tag: 6, value: bytes}), do: decode_oid(bytes)
  def oid(_), do: nil

  @doc "The integer of an INTEGER element."
  def integer(%{class: :universal, tag: 2, value: bytes}) when byte_size(bytes) > 0 do
    size = bit_size(bytes)
    <<n::signed-size(size)>> = bytes
    n
  end

  def integer(_), do: nil

  @doc "Content bytes of a primitive element."
  def bytes(%{value: v}) when is_binary(v), do: v
  def bytes(_), do: nil

  defp decode_oid(<<first, rest::binary>>) do
    {a, b} =
      cond do
        first < 40 -> {0, first}
        first < 80 -> {1, first - 40}
        true -> {2, first - 80}
      end

    [a, b | arcs(rest, 0, [])] |> List.to_tuple()
  end

  defp decode_oid(_), do: nil

  defp arcs(<<>>, _acc, out), do: Enum.reverse(out)
  defp arcs(<<1::1, b::7, rest::binary>>, acc, out), do: arcs(rest, acc <<< 7 ||| b, out)
  defp arcs(<<0::1, b::7, rest::binary>>, acc, out), do: arcs(rest, 0, [acc <<< 7 ||| b | out])

  @doc "Parses a UTCTime or GeneralizedTime element into a DateTime."
  def time(%{class: :universal, tag: 23, value: v}), do: parse_time(to_string(v), :utc)
  def time(%{class: :universal, tag: 24, value: v}), do: parse_time(to_string(v), :generalized)
  def time(_), do: nil

  @doc false
  def parse_time(s, kind) do
    s = String.trim_trailing(s, "Z")

    {year, rest} =
      case kind do
        :utc ->
          <<yy::binary-2, rest::binary>> = s
          y = String.to_integer(yy)
          {if(y >= 50, do: 1900 + y, else: 2000 + y), rest}

        :generalized ->
          <<yyyy::binary-4, rest::binary>> = s
          {String.to_integer(yyyy), rest}
      end

    <<mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, rest::binary>> = rest
    se = if byte_size(rest) >= 2, do: binary_part(rest, 0, 2), else: "00"

    NaiveDateTime.new!(
      year,
      String.to_integer(mo),
      String.to_integer(d),
      String.to_integer(h),
      String.to_integer(mi),
      String.to_integer(se)
    )
    |> DateTime.from_naive!("Etc/UTC")
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------- encoding

  @doc "A SEQUENCE of already encoded elements."
  def sequence(items), do: tlv(0x30, items)

  @doc "A SET of already encoded elements (sorted, as DER requires for SET OF)."
  def set(items), do: tlv(0x31, items |> Enum.map(&IO.iodata_to_binary/1) |> Enum.sort())

  @doc "A context-specific tag around encoded content (`constructed?` true by default)."
  def context(n, items, constructed? \\ true),
    do: tlv(0x80 ||| if(constructed?, do: 0x20, else: 0) ||| n, items)

  @doc "An OBJECT IDENTIFIER."
  def oid_der(oid) when is_tuple(oid) do
    [a, b | rest] = Tuple.to_list(oid)
    tlv(0x06, [base128(a * 40 + b) | Enum.map(rest, &base128/1)])
  end

  defp base128(n) when n < 128, do: <<n>>

  defp base128(n) do
    bytes = digits128(n, [])
    {init, [last]} = Enum.split(bytes, -1)
    IO.iodata_to_binary(Enum.map(init, &<<1::1, &1::7>>) ++ [<<0::1, last::7>>])
  end

  defp digits128(0, acc), do: acc
  defp digits128(n, acc), do: digits128(n >>> 7, [n &&& 0x7F | acc])

  @doc "An INTEGER."
  def integer_der(n) when n >= 0 do
    bytes = :binary.encode_unsigned(n)
    bytes = if :binary.first(bytes) >= 0x80, do: <<0>> <> bytes, else: bytes
    tlv(0x02, bytes)
  end

  @doc "An OCTET STRING."
  def octet_string(bytes), do: tlv(0x04, bytes)

  @doc "NULL."
  def null, do: <<5, 0>>

  @doc "A UTCTime (years 1950–2049) or GeneralizedTime."
  def time_der(%DateTime{} = dt) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC")

    if dt.year >= 1950 and dt.year < 2050,
      do: tlv(0x17, Calendar.strftime(dt, "%y%m%d%H%M%SZ")),
      else: tlv(0x18, Calendar.strftime(dt, "%Y%m%d%H%M%SZ"))
  end

  @doc "An AlgorithmIdentifier SEQUENCE, with NULL parameters unless `params: false`."
  def algorithm(oid, params \\ true) do
    sequence([oid_der(oid) | if(params, do: [null()], else: [])])
  end

  @doc "A tag-length-value with the given identifier byte."
  def tlv(id, content) do
    content = IO.iodata_to_binary(content)
    IO.iodata_to_binary([id, encode_length(byte_size(content)), content])
  end

  defp encode_length(n) when n < 128, do: <<n>>

  defp encode_length(n) do
    bytes = :binary.encode_unsigned(n)
    <<0x80 ||| byte_size(bytes), bytes::binary>>
  end
end
