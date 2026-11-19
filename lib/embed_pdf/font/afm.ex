defmodule EmbedPdf.Font.AFM do
  @moduledoc """
  Metrics of the 14 standard fonts, compiled from Adobe's Core14 AFM files,
  and the mapping of common font names onto them.
  """

  @dir Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "afm"]))
  @files Path.wildcard(Path.join(@dir, "*.afm"))
  for f <- @files, do: @external_resource(f)

  parse = fn path ->
    lines = path |> File.read!() |> String.split(~r/\r?\n/)

    header =
      for line <- lines, reduce: %{} do
        acc ->
          case String.split(line, " ", parts: 2) do
            [k, v]
            when k in ~w(FontName FamilyName Weight ItalicAngle IsFixedPitch FontBBox CapHeight XHeight Ascender Descender EncodingScheme StdVW) ->
              Map.put(acc, k, String.trim(v))

            _ ->
              acc
          end
      end

    chars =
      for line <- lines, String.starts_with?(line, "C "), reduce: {%{}, %{}} do
        {by_name, by_code} ->
          fields =
            line
            |> String.split(";")
            |> Enum.map(&String.trim/1)
            |> Enum.map(&String.split(&1, " ", parts: 2))
            |> Enum.flat_map(fn
              [k, v] -> [{k, v}]
              _ -> []
            end)
            |> Map.new()

          code = String.to_integer(fields["C"])
          width = String.to_integer(fields["WX"])
          name = fields["N"]
          by_code = if code >= 0, do: Map.put(by_code, code, name), else: by_code
          {Map.put(by_name, name, width), by_code}
      end

    num = fn key, default ->
      case header[key] do
        nil -> default
        v -> v |> String.split(" ") |> hd() |> Float.parse() |> elem(0)
      end
    end

    bbox =
      case header["FontBBox"] do
        nil -> [0, -200, 1000, 800]
        v -> v |> String.split(" ", trim: true) |> Enum.map(&String.to_integer/1)
      end

    {widths, encoding} = chars

    {header["FontName"],
     %{
       name: header["FontName"],
       widths: widths,
       encoding: encoding,
       ascent: num.("Ascender", Enum.at(bbox, 3) / 1),
       descent: num.("Descender", Enum.at(bbox, 1) / 1),
       cap_height: num.("CapHeight", 700.0),
       italic_angle: num.("ItalicAngle", 0.0),
       fixed?: header["IsFixedPitch"] == "true",
       bbox: bbox
     }}
  end

  @fonts @files |> Enum.map(parse) |> Map.new()

  @doc "Metrics for a standard font name (`\"Helvetica-Bold\"`), or nil."
  @spec get(String.t() | nil) :: map() | nil
  def get(nil), do: nil
  def get(name), do: Map.get(@fonts, name)

  @doc "All standard font names."
  def names, do: Map.keys(@fonts)

  @doc """
  Maps a base font name (with subset tags, commas and common aliases) to
  one of the 14 standard fonts, or nil when it is not one of them.
  """
  @spec standard_name(String.t() | nil) :: String.t() | nil
  def standard_name(nil), do: nil

  def standard_name(base) do
    name = base |> strip_subset() |> String.replace([",", " "], "-") |> String.replace("--", "-")
    lower = String.downcase(name)

    family =
      cond do
        String.contains?(lower, "zapfdingbats") or String.contains?(lower, "dingbats") -> :zapf
        lower in ["symbol", "symbolmt"] or String.starts_with?(lower, "symbol-") -> :symbol
        String.contains?(lower, "courier") -> :courier
        String.contains?(lower, "times") -> :times
        String.contains?(lower, "helvetica") or String.contains?(lower, "arial") -> :helvetica
        true -> nil
      end

    bold? =
      String.contains?(lower, "bold") or String.contains?(lower, "black") or
        String.contains?(lower, "heavy")

    italic? = String.contains?(lower, "italic") or String.contains?(lower, "oblique")

    case family do
      nil ->
        nil

      :zapf ->
        "ZapfDingbats"

      :symbol ->
        "Symbol"

      :courier ->
        style("Courier", bold?, italic?, "Oblique")

      :helvetica ->
        style("Helvetica", bold?, italic?, "Oblique")

      :times ->
        if(not bold? and not italic?,
          do: "Times-Roman",
          else: style("Times", bold?, italic?, "Italic")
        )
    end
  end

  defp style(base, false, false, _), do: base
  defp style(base, true, false, _), do: base <> "-Bold"
  defp style(base, false, true, slant), do: base <> "-" <> slant
  defp style(base, true, true, slant), do: base <> "-Bold" <> slant

  @doc "Removes a six-letter subset tag (`ABCDEF+Name`)."
  def strip_subset(<<tag::binary-6, "+", rest::binary>>) do
    if tag =~ ~r/^[A-Z]{6}$/, do: rest, else: tag <> "+" <> rest
  end

  def strip_subset(name), do: name
end
