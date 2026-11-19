defmodule EmbedPdf.PDF.Content do
  @moduledoc """
  Content stream parsing (ISO 32000-1, 7.8): turns a content stream into a
  list of `{operator, operands}`. Inline images come back as
  `{"BI", [%{dict: dict, data: bytes}]}`.
  """

  alias EmbedPdf.PDF.Parser

  @doc "Parses decoded content stream bytes into operations."
  @spec parse(binary()) :: [{String.t(), list()}]
  def parse(data) when is_binary(data), do: loop(data, [], [])

  defp loop(input, operands, ops) do
    case Parser.parse_value(input, refs: false) do
      :eof ->
        Enum.reverse(ops)

      {{:keyword, "BI"}, rest} ->
        {image, rest} = inline_image(rest)
        loop(rest, [], [{"BI", [image]} | ops])

      {{:keyword, ""}, rest} ->
        loop(rest, operands, ops)

      {{:keyword, op}, rest} when op in ["]", ")", ">", "}", "{"] ->
        loop(rest, operands, ops)

      {{:keyword, op}, rest} ->
        loop(rest, [], [{op, Enum.reverse(operands)} | ops])

      {value, rest} ->
        loop(rest, [value | operands], ops)
    end
  end

  @abbrev %{
    "BPC" => "BitsPerComponent",
    "CS" => "ColorSpace",
    "D" => "Decode",
    "DP" => "DecodeParms",
    "F" => "Filter",
    "H" => "Height",
    "IM" => "ImageMask",
    "I" => "Interpolate",
    "W" => "Width",
    "L" => "Length"
  }

  @value_abbrev %{
    "G" => "DeviceGray",
    "RGB" => "DeviceRGB",
    "CMYK" => "DeviceCMYK",
    "I" => "Indexed",
    "AHx" => "ASCIIHexDecode",
    "A85" => "ASCII85Decode",
    "LZW" => "LZWDecode",
    "Fl" => "FlateDecode",
    "RL" => "RunLengthDecode",
    "CCF" => "CCITTFaxDecode",
    "DCT" => "DCTDecode"
  }

  defp inline_image(input) do
    {dict, rest} = inline_dict(input, %{})

    # a single whitespace byte separates ID from the data
    rest =
      case rest do
        <<"\r\n", r::binary>> -> r
        <<c, r::binary>> when c in [0, 9, 10, 12, 13, 32] -> r
        r -> r
      end

    {data, rest} = inline_data(dict, rest)
    {%{dict: dict, data: data}, rest}
  end

  defp inline_dict(input, acc) do
    case Parser.parse_value(input, refs: false) do
      {{:keyword, "ID"}, rest} ->
        {acc, rest}

      :eof ->
        {acc, <<>>}

      {key, rest} when is_binary(key) ->
        case Parser.parse_value(rest, refs: false) do
          {{:keyword, "ID"}, rest2} -> {acc, rest2}
          :eof -> {acc, <<>>}
          {value, rest2} -> inline_dict(rest2, Map.put(acc, expand_key(key), expand_value(value)))
        end

      {_junk, rest} ->
        inline_dict(rest, acc)
    end
  end

  defp expand_key(k), do: Map.get(@abbrev, k, k)
  defp expand_value(v) when is_binary(v), do: Map.get(@value_abbrev, v, v)
  defp expand_value(list) when is_list(list), do: Enum.map(list, &expand_value/1)
  defp expand_value(v), do: v

  defp inline_data(dict, rest) do
    filters = List.wrap(dict["Filter"])

    case expected_length(dict) do
      len when is_integer(len) and filters == [] and len <= byte_size(rest) ->
        <<data::binary-size(len), after_data::binary>> = rest

        after_ws = Parser.skip_ws(after_data)

        if String.starts_with?(after_ws, "EI"),
          do: {data, binary_part(after_ws, 2, byte_size(after_ws) - 2)},
          else: scan_ei(rest)

      _ ->
        scan_ei(rest)
    end
  end

  defp expected_length(dict) do
    with w when is_integer(w) <- dict["Width"],
         h when is_integer(h) <- dict["Height"] do
      {comps, bpc} =
        if dict["ImageMask"] == true do
          {1, 1}
        else
          comps =
            case dict["ColorSpace"] do
              "DeviceRGB" -> 3
              "DeviceCMYK" -> 4
              ["Indexed" | _] -> 1
              _ -> 1
            end

          {comps, dict["BitsPerComponent"] || 8}
        end

      div(w * comps * bpc + 7, 8) * h
    else
      _ -> nil
    end
  end

  # EI preceded by whitespace and followed by whitespace or end of data
  defp scan_ei(data), do: scan_ei(data, 0)

  defp scan_ei(data, from) do
    case :binary.match(data, "EI", scope: {from, byte_size(data) - from}) do
      {pos, 2} ->
        before_ok = pos == 0 or :binary.at(data, pos - 1) in [0, 9, 10, 12, 13, 32]
        after_pos = pos + 2

        after_ok =
          after_pos >= byte_size(data) or :binary.at(data, after_pos) in [0, 9, 10, 12, 13, 32]

        if before_ok and after_ok do
          img = binary_part(data, 0, max(pos - 1, 0))
          {img, binary_part(data, after_pos, byte_size(data) - after_pos)}
        else
          scan_ei(data, pos + 2)
        end

      :nomatch ->
        {data, <<>>}
    end
  end
end
