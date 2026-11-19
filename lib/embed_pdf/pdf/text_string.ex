defmodule EmbedPdf.PDF.TextString do
  @moduledoc """
  Text strings (ISO 32000-2, 7.9.2): UTF-16BE with BOM, UTF-8 with BOM, or
  PDFDocEncoding. `decode/1` turns them into UTF-8; `encode/1` writes UTF-8
  back as PDFDocEncoding when possible, else as UTF-16BE.
  """

  import Bitwise

  # PDFDocEncoding differs from Latin-1 in 0x18..0x1F and 0x80..0xA0
  @pdfdoc %{
    0x18 => 0x02D8,
    0x19 => 0x02C7,
    0x1A => 0x02C6,
    0x1B => 0x02D9,
    0x1C => 0x02DD,
    0x1D => 0x02DB,
    0x1E => 0x02DA,
    0x1F => 0x02DC,
    0x80 => 0x2022,
    0x81 => 0x2020,
    0x82 => 0x2021,
    0x83 => 0x2026,
    0x84 => 0x2014,
    0x85 => 0x2013,
    0x86 => 0x0192,
    0x87 => 0x2044,
    0x88 => 0x2039,
    0x89 => 0x203A,
    0x8A => 0x2212,
    0x8B => 0x2030,
    0x8C => 0x201E,
    0x8D => 0x201C,
    0x8E => 0x201D,
    0x8F => 0x2018,
    0x90 => 0x2019,
    0x91 => 0x201A,
    0x92 => 0x2122,
    0x93 => 0xFB01,
    0x94 => 0xFB02,
    0x95 => 0x0141,
    0x96 => 0x0152,
    0x97 => 0x0160,
    0x98 => 0x0178,
    0x99 => 0x017D,
    0x9A => 0x0131,
    0x9B => 0x0142,
    0x9C => 0x0153,
    0x9D => 0x0161,
    0x9E => 0x017E,
    0xA0 => 0x20AC
  }
  @reverse Map.new(@pdfdoc, fn {k, v} -> {v, k} end)

  @doc "Decodes a PDF text string (`{:string, bytes}` or bytes) to UTF-8."
  @spec decode(term()) :: String.t()
  def decode({:string, s}), do: decode(s)
  def decode(<<0xFE, 0xFF, rest::binary>>), do: utf16(rest)
  def decode(<<0xFF, 0xFE, rest::binary>>), do: utf16le(rest)

  def decode(<<0xEF, 0xBB, 0xBF, rest::binary>>),
    do: if(String.valid?(rest), do: rest, else: pdfdoc(rest))

  def decode(s) when is_binary(s), do: pdfdoc(s)
  def decode(_), do: ""

  defp utf16(data) do
    data = if rem(byte_size(data), 2) == 1, do: data <> <<0>>, else: data

    case :unicode.characters_to_binary(data, {:utf16, :big}) do
      s when is_binary(s) -> strip_lang(s)
      _ -> pdfdoc(data)
    end
  end

  defp utf16le(data) do
    data = if rem(byte_size(data), 2) == 1, do: data <> <<0>>, else: data

    case :unicode.characters_to_binary(data, {:utf16, :little}) do
      s when is_binary(s) -> s
      _ -> pdfdoc(data)
    end
  end

  # language escape sequences: U+001B lang U+001B
  defp strip_lang(s), do: String.replace(s, ~r/\x{1B}[^\x{1B}]*\x{1B}/u, "")

  defp pdfdoc(s) do
    for <<b <- s>>, into: <<>> do
      cp = Map.get(@pdfdoc, b, b)
      if cp in 0xD800..0xDFFF, do: <<0xFFFD::utf8>>, else: <<cp::utf8>>
    end
  end

  @doc "Encodes UTF-8 as a PDF text string body (PDFDocEncoding or UTF-16BE with BOM)."
  @spec encode(String.t()) :: binary()
  def encode(text) do
    cps = String.to_charlist(text)

    if Enum.all?(cps, &pdfdoc_encodable?/1) do
      for cp <- cps, into: <<>>, do: <<Map.get(@reverse, cp, cp)>>
    else
      <<0xFE, 0xFF>> <> :unicode.characters_to_binary(text, :utf8, {:utf16, :big})
    end
  end

  defp pdfdoc_encodable?(cp) when cp < 0x18, do: cp in [9, 10, 13]
  defp pdfdoc_encodable?(cp) when cp in 0x18..0x1F, do: false
  defp pdfdoc_encodable?(cp) when cp < 0x7F, do: true
  defp pdfdoc_encodable?(cp) when cp >= 0xA1 and cp <= 0xFF, do: true
  defp pdfdoc_encodable?(cp), do: Map.has_key?(@reverse, cp)

  @doc "Parses a PDF date `D:YYYYMMDDHHmmSSOHH'mm` into a `DateTime` (or nil)."
  @spec parse_date(term()) :: DateTime.t() | nil
  def parse_date({:string, s}), do: parse_date(decode(s))

  def parse_date(s) when is_binary(s) do
    case Regex.run(
           ~r/^(?:D:)?(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?([Zz+\-])?(\d{2})?'?(\d{2})?/,
           String.trim(s)
         ) do
      [_, y | rest] ->
        [mo, d, h, mi, se, tz, tzh, tzm] = rest ++ List.duplicate("", 8 - length(rest))
        int = fn v, default -> if v in ["", nil], do: default, else: String.to_integer(v) end

        with {:ok, date} <-
               Date.new(int.(y, 1970), clamp(int.(mo, 1), 1, 12), clamp(int.(d, 1), 1, 31)),
             {:ok, time} <-
               Time.new(
                 clamp(int.(h, 0), 0, 23),
                 clamp(int.(mi, 0), 0, 59),
                 clamp(int.(se, 0), 0, 59)
               ),
             {:ok, ndt} <- {:ok, NaiveDateTime.new!(date, time)} do
          offset = (int.(tzh, 0) * 60 + int.(tzm, 0)) * 60
          offset = if tz == "-", do: -offset, else: offset
          ndt |> NaiveDateTime.add(-offset) |> DateTime.from_naive!("Etc/UTC")
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_date(_), do: nil

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  @doc "Formats a `DateTime` as a PDF date string body."
  @spec format_date(DateTime.t()) :: String.t()
  def format_date(%DateTime{} = dt) do
    dt = DateTime.shift_zone!(dt, "Etc/UTC")
    "D:" <> Calendar.strftime(dt, "%Y%m%d%H%M%S") <> "Z"
  end

  @doc false
  def utf16_units(cp) when cp > 0xFFFF do
    v = cp - 0x10000
    [0xD800 ||| v >>> 10, 0xDC00 ||| (v &&& 0x3FF)]
  end

  def utf16_units(cp), do: [cp]
end
