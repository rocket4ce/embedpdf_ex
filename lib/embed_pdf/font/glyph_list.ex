defmodule EmbedPdf.Font.GlyphList do
  @moduledoc """
  Glyph name → Unicode, from the Adobe Glyph List (and its ZapfDingbats
  companion) plus the `uniXXXX` / `uXXXX` naming conventions.
  """

  @agl Path.join([__DIR__, "..", "..", "..", "priv", "agl", "glyphlist.txt"]) |> Path.expand()
  @zapf Path.join([__DIR__, "..", "..", "..", "priv", "agl", "glyphlist-zapfdingbats.txt"])
        |> Path.expand()
  @external_resource @agl
  @external_resource @zapf

  parse = fn path ->
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ";") do
        [name, hex] ->
          cps = hex |> String.split(" ") |> Enum.map(&String.to_integer(&1, 16))
          [{name, List.to_string(cps)}]

        _ ->
          []
      end
    end)
  end

  @names Map.new(parse.(@agl))
  @zapf_names Map.new(parse.(@zapf))

  # preferred names when several glyph names share a code point
  @preferred %{
    " " => "space",
    "-" => "hyphen",
    " " => "space",
    "­" => "hyphen",
    "'" => "quotesingle",
    "’" => "quoteright",
    "‘" => "quoteleft",
    "Δ" => "Delta",
    "Ω" => "Omega",
    "µ" => "mu",
    "∕" => "fraction",
    "⁄" => "fraction",
    "¯" => "macron",
    "ˉ" => "macron",
    "ı" => "dotlessi",
    "∙" => "periodcentered",
    "·" => "periodcentered"
  }

  @reverse @names
           |> Enum.sort_by(fn {name, _} -> {String.length(name), name} end, :desc)
           |> Map.new(fn {name, uni} -> {uni, name} end)
           |> Map.merge(@preferred)

  @doc "Unicode text of a glyph name, or nil."
  @spec to_unicode(String.t(), boolean()) :: String.t() | nil
  def to_unicode(name, zapf? \\ false)
  def to_unicode(nil, _), do: nil

  def to_unicode(name, true) do
    Map.get(@zapf_names, name) || to_unicode(name, false)
  end

  def to_unicode(name, false) do
    case Map.fetch(@names, name) do
      {:ok, u} -> u
      :error -> convention(name)
    end
  end

  defp convention(<<"uni", hex::binary>>)
       when byte_size(hex) >= 4 and rem(byte_size(hex), 4) == 0 do
    cps = for <<chunk::binary-4 <- hex>>, do: Integer.parse(chunk, 16)

    if Enum.all?(cps, &match?({_, ""}, &1)),
      do:
        cps
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&valid_cp?/1)
        |> List.to_string()
        |> nil_if_empty(),
      else: nil
  end

  defp convention(<<"u", hex::binary>>) when byte_size(hex) in 4..6 do
    case Integer.parse(hex, 16) do
      {cp, ""} -> if valid_cp?(cp), do: <<cp::utf8>>, else: nil
      _ -> nil
    end
  end

  defp convention(name) do
    cond do
      # "a.sc", "f_f_i" style names
      String.contains?(name, ".") ->
        name
        |> String.split(".", parts: 2)
        |> hd()
        |> then(&if(&1 == "", do: nil, else: to_unicode(&1)))

      String.contains?(name, "_") ->
        parts = name |> String.split("_") |> Enum.map(&to_unicode/1)
        if Enum.all?(parts), do: Enum.join(parts), else: nil

      true ->
        nil
    end
  end

  defp valid_cp?(cp), do: cp >= 0 and cp <= 0x10FFFF and cp not in 0xD800..0xDFFF

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  @doc "The usual glyph name for a Unicode string (single character), or nil."
  @spec to_name(String.t()) :: String.t() | nil
  def to_name(uni) do
    case Map.fetch(@reverse, uni) do
      {:ok, name} ->
        name

      :error ->
        case String.to_charlist(uni) do
          [cp] when cp <= 0xFFFF -> "uni" <> String.pad_leading(Integer.to_string(cp, 16), 4, "0")
          [cp] -> "u" <> Integer.to_string(cp, 16)
          _ -> nil
        end
    end
  end

  @doc "Whether the name is in the glyph list."
  def known?(name), do: Map.has_key?(@names, name)
end
