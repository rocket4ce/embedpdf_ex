defmodule EmbedPdf.Font.Encoding do
  @moduledoc """
  The predefined simple-font encodings (ISO 32000-1, Annex D) as code →
  glyph name tables, and `/Differences` handling.
  """

  alias EmbedPdf.Font.AFM

  @ascii ~w(space exclam quotedbl numbersign dollar percent ampersand quotesingle
            parenleft parenright asterisk plus comma hyphen period slash zero one two
            three four five six seven eight nine colon semicolon less equal greater
            question at A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft
            backslash bracketright asciicircum underscore grave a b c d e f g h i j k l m
            n o p q r s t u v w x y z braceleft bar braceright asciitilde)

  @win_high %{
    0x80 => "Euro",
    0x82 => "quotesinglbase",
    0x83 => "florin",
    0x84 => "quotedblbase",
    0x85 => "ellipsis",
    0x86 => "dagger",
    0x87 => "daggerdbl",
    0x88 => "circumflex",
    0x89 => "perthousand",
    0x8A => "Scaron",
    0x8B => "guilsinglleft",
    0x8C => "OE",
    0x8E => "Zcaron",
    0x91 => "quoteleft",
    0x92 => "quoteright",
    0x93 => "quotedblleft",
    0x94 => "quotedblright",
    0x95 => "bullet",
    0x96 => "endash",
    0x97 => "emdash",
    0x98 => "tilde",
    0x99 => "trademark",
    0x9A => "scaron",
    0x9B => "guilsinglright",
    0x9C => "oe",
    0x9E => "zcaron",
    0x9F => "Ydieresis",
    0x81 => "bullet",
    0x8D => "bullet",
    0x8F => "bullet",
    0x90 => "bullet",
    0x9D => "bullet",
    0x7F => "bullet"
  }

  @latin1_upper ~w(space exclamdown cent sterling currency yen brokenbar section dieresis
                   copyright ordfeminine guillemotleft logicalnot hyphen registered macron
                   degree plusminus twosuperior threesuperior acute mu paragraph
                   periodcentered cedilla onesuperior ordmasculine guillemotright onequarter
                   onehalf threequarters questiondown Agrave Aacute Acircumflex Atilde
                   Adieresis Aring AE Ccedilla Egrave Eacute Ecircumflex Edieresis Igrave
                   Iacute Icircumflex Idieresis Eth Ntilde Ograve Oacute Ocircumflex Otilde
                   Odieresis multiply Oslash Ugrave Uacute Ucircumflex Udieresis Yacute Thorn
                   germandbls agrave aacute acircumflex atilde adieresis aring ae ccedilla
                   egrave eacute ecircumflex edieresis igrave iacute icircumflex idieresis eth
                   ntilde ograve oacute ocircumflex otilde odieresis divide oslash ugrave
                   uacute ucircumflex udieresis yacute thorn ydieresis)

  @mac_upper ~w(Adieresis Aring Ccedilla Eacute Ntilde Odieresis Udieresis aacute agrave
                acircumflex adieresis atilde aring ccedilla eacute egrave ecircumflex
                edieresis iacute igrave icircumflex idieresis ntilde oacute ograve
                ocircumflex odieresis otilde uacute ugrave ucircumflex udieresis dagger
                degree cent sterling section bullet paragraph germandbls registered
                copyright trademark acute dieresis notequal AE Oslash infinity plusminus
                lessequal greaterequal yen mu partialdiff summation product pi integral
                ordfeminine ordmasculine Omega ae oslash questiondown exclamdown logicalnot
                radical florin approxequal Delta guillemotleft guillemotright ellipsis space
                Agrave Atilde Otilde OE oe endash emdash quotedblleft quotedblright
                quoteleft quoteright divide lozenge ydieresis Ydieresis fraction currency
                guilsinglleft guilsinglright fi fl daggerdbl periodcentered quotesinglbase
                quotedblbase perthousand Acircumflex Ecircumflex Aacute Edieresis Egrave
                Iacute Icircumflex Idieresis Igrave Oacute Ocircumflex apple Ograve Uacute
                Ucircumflex Ugrave dotlessi circumflex tilde macron breve dotaccent ring
                cedilla hungarumlaut ogonek caron)

  @ascii_map @ascii |> Enum.with_index(0x20) |> Map.new(fn {n, i} -> {i, n} end)

  @win @ascii_map
       |> Map.merge(@win_high)
       |> Map.merge(@latin1_upper |> Enum.with_index(0xA0) |> Map.new(fn {n, i} -> {i, n} end))

  @mac @ascii_map
       |> Map.merge(@mac_upper |> Enum.with_index(0x80) |> Map.new(fn {n, i} -> {i, n} end))

  @standard AFM.get("Times-Roman").encoding
  @symbol AFM.get("Symbol").encoding
  @zapf AFM.get("ZapfDingbats").encoding

  @pdfdoc @win
          |> Map.merge(%{
            0x18 => "breve",
            0x19 => "caron",
            0x1A => "circumflex",
            0x1B => "dotaccent",
            0x1C => "hungarumlaut",
            0x1D => "ogonek",
            0x1E => "ring",
            0x1F => "tilde",
            0x80 => "bullet",
            0x81 => "dagger",
            0x82 => "daggerdbl",
            0x83 => "ellipsis",
            0x84 => "emdash",
            0x85 => "endash",
            0x86 => "florin",
            0x87 => "fraction",
            0x88 => "guilsinglleft",
            0x89 => "guilsinglright",
            0x8A => "minus",
            0x8B => "perthousand",
            0x8C => "quotedblbase",
            0x8D => "quotedblleft",
            0x8E => "quotedblright",
            0x8F => "quoteleft",
            0x90 => "quoteright",
            0x91 => "quotesinglbase",
            0x92 => "trademark",
            0x93 => "fi",
            0x94 => "fl",
            0x95 => "Lslash",
            0x96 => "OE",
            0x97 => "Scaron",
            0x98 => "Ydieresis",
            0x99 => "Zcaron",
            0x9A => "dotlessi",
            0x9B => "lslash",
            0x9C => "oe",
            0x9D => "scaron",
            0x9E => "zcaron",
            0xA0 => "Euro"
          })

  @doc "A named encoding as a `%{code => glyph_name}` map, or nil."
  @spec named(String.t() | nil) :: map() | nil
  def named("WinAnsiEncoding"), do: @win
  def named("MacRomanEncoding"), do: @mac
  def named("StandardEncoding"), do: @standard
  def named("MacExpertEncoding"), do: @standard
  def named("PDFDocEncoding"), do: @pdfdoc
  def named("SymbolEncoding"), do: @symbol
  def named("ZapfDingbatsEncoding"), do: @zapf
  def named(_), do: nil

  @doc "Built-in encoding of a standard font."
  def builtin("Symbol"), do: @symbol
  def builtin("ZapfDingbats"), do: @zapf
  def builtin(_), do: @standard

  @doc "Applies a `/Differences` array to an encoding map."
  @spec apply_differences(map(), list()) :: map()
  def apply_differences(base, diffs) when is_list(diffs) do
    {map, _} =
      Enum.reduce(diffs, {base, 0}, fn
        code, {map, _} when is_integer(code) -> {map, code}
        name, {map, code} when is_binary(name) -> {Map.put(map, code, name), code + 1}
        _, acc -> acc
      end)

    map
  end

  def apply_differences(base, _), do: base
end
