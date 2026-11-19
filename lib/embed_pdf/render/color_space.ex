defmodule EmbedPdf.Render.ColorSpace do
  @moduledoc """
  Color spaces (ISO 32000-1, 8.6) and their conversion to sRGB.

  A parsed color space is one of:

    * `:gray`, `:rgb`, `:cmyk`, `{:lab, white, range}`
    * `{:indexed, base, hival, lookup_bytes}`
    * `{:separation, n, alternate, function}` (also DeviceN)
    * `{:pattern, underlying | nil}`

  Colors are `{r, g, b}` floats in 0..1.
  """

  alias EmbedPdf.PDF.{Document, Stream}
  alias EmbedPdf.Render.Function, as: PdfFunction

  @type t :: term()

  @doc "Parses a color space value (a name, an array, or a resource name)."
  @spec parse(Document.t(), term(), map() | nil) :: t()
  def parse(doc, value, resources \\ nil),
    do: do_parse(doc, Document.resolve(doc, value), resources, 0)

  defp do_parse(_doc, _value, _res, depth) when depth > 8, do: :gray

  defp do_parse(doc, name, resources, depth) when is_binary(name) do
    case name do
      n when n in ["DeviceGray", "G", "CalGray"] ->
        :gray

      n when n in ["DeviceRGB", "RGB", "CalRGB"] ->
        :rgb

      n when n in ["DeviceCMYK", "CMYK"] ->
        :cmyk

      "Pattern" ->
        {:pattern, nil}

      "Indexed" ->
        :gray

      other ->
        # a named resource from /ColorSpace
        case resources && Document.get(doc, Document.get(doc, resources, "ColorSpace"), other) do
          nil -> :rgb
          cs -> do_parse(doc, cs, resources, depth + 1)
        end
    end
  end

  defp do_parse(doc, [head | rest], resources, depth) do
    head = Document.resolve(doc, head)
    rest = Enum.map(rest, &Document.resolve(doc, &1))

    case head do
      n when n in ["DeviceGray", "CalGray", "G"] ->
        :gray

      n when n in ["DeviceRGB", "CalRGB", "RGB"] ->
        :rgb

      n when n in ["DeviceCMYK", "CMYK"] ->
        :cmyk

      "Lab" ->
        params = List.first(rest) || %{}
        white = Document.resolve(doc, params["WhitePoint"]) || [0.9505, 1.0, 1.089]
        range = Document.resolve(doc, params["Range"]) || [-100, 100, -100, 100]
        {:lab, white, range}

      "ICCBased" ->
        case List.first(rest) do
          %Stream{dict: dict} ->
            alt = Document.resolve(doc, dict["Alternate"])

            case Document.resolve(doc, dict["N"]) do
              1 -> :gray
              3 -> if alt, do: do_parse(doc, alt, resources, depth + 1) |> icc3(), else: :rgb
              4 -> :cmyk
              _ -> if alt, do: do_parse(doc, alt, resources, depth + 1), else: :rgb
            end

          _ ->
            :rgb
        end

      n when n in ["Indexed", "I"] ->
        [base, hival, lookup | _] = rest ++ [nil, nil, nil]
        base_cs = do_parse(doc, base, resources, depth + 1)

        bytes =
          case lookup do
            {:string, s} -> s
            %Stream{} = s -> Document.stream_data(doc, s) || <<>>
            _ -> <<>>
          end

        {:indexed, base_cs, if(is_integer(hival), do: hival, else: 255), bytes}

      "Separation" ->
        [name, alt, func | _] = rest ++ [nil, nil, nil]

        cond do
          name == "None" ->
            {:none, 1}

          true ->
            {:separation, 1, do_parse(doc, alt, resources, depth + 1),
             PdfFunction.parse(doc, func)}
        end

      "DeviceN" ->
        [names, alt, func | _] = rest ++ [nil, nil, nil]
        n = if is_list(names), do: length(names), else: 1
        {:separation, n, do_parse(doc, alt, resources, depth + 1), PdfFunction.parse(doc, func)}

      "Pattern" ->
        case rest do
          [under | _] when under != nil -> {:pattern, do_parse(doc, under, resources, depth + 1)}
          _ -> {:pattern, nil}
        end

      _ ->
        :rgb
    end
  end

  defp do_parse(_doc, _value, _res, _depth), do: :gray

  defp icc3(:rgb), do: :rgb
  defp icc3({:lab, _, _} = lab), do: lab
  defp icc3(_), do: :rgb

  @doc "Number of color components."
  @spec components(t()) :: pos_integer()
  def components(:gray), do: 1
  def components(:rgb), do: 3
  def components(:cmyk), do: 4
  def components({:lab, _, _}), do: 3
  def components({:indexed, _, _, _}), do: 1
  def components({:separation, n, _, _}), do: n
  def components({:none, n}), do: n
  def components({:pattern, _}), do: 1

  @doc "The initial color of a space (8.6.5)."
  @spec initial(t()) :: [number()]
  def initial(:cmyk), do: [0, 0, 0, 1]
  def initial({:lab, _, _}), do: [0, 0, 0]
  def initial({:separation, n, _, _}), do: List.duplicate(1, n)
  def initial(cs), do: List.duplicate(0, components(cs))

  @doc "Converts components to `{r, g, b}`."
  @spec to_rgb(t(), [number()]) :: {float(), float(), float()}
  def to_rgb(:gray, [g | _]), do: {clamp(g), clamp(g), clamp(g)}
  def to_rgb(:rgb, [r, g, b | _]), do: {clamp(r), clamp(g), clamp(b)}

  def to_rgb(:cmyk, [c, m, y, k | _]) do
    {clamp((1 - c) * (1 - k)), clamp((1 - m) * (1 - k)), clamp((1 - y) * (1 - k))}
  end

  def to_rgb({:lab, [xw, yw, zw | _], _range}, [l, a, b | _]) do
    m = (l + 16) / 116
    lf = m + a / 500
    nf = m - b / 200
    g = fn t -> if t >= 6 / 29, do: t * t * t, else: 108 / 841 * (t - 4 / 29) end
    x = xw * g.(lf)
    y = yw * g.(m)
    z = zw * g.(nf)
    r = 3.2406 * x - 1.5372 * y - 0.4986 * z
    gg = -0.9689 * x + 1.8758 * y + 0.0415 * z
    bb = 0.0557 * x - 0.204 * y + 1.057 * z
    {gamma(r), gamma(gg), gamma(bb)}
  end

  def to_rgb({:indexed, base, hival, lookup}, [i | _]) do
    n = components(base)
    i = i |> round() |> max(0) |> min(hival)
    offset = i * n

    if offset + n <= byte_size(lookup) do
      comps = for <<b <- binary_part(lookup, offset, n)>>, do: b / 255
      to_rgb(base, comps)
    else
      {0.0, 0.0, 0.0}
    end
  end

  def to_rgb({:separation, _n, alt, func}, comps) do
    out = PdfFunction.eval(func, comps)
    out = if out == [], do: [1 - (List.first(comps) || 0)], else: out
    to_rgb(alt, pad(out, components(alt)))
  end

  def to_rgb({:none, _}, _), do: {1.0, 1.0, 1.0}
  def to_rgb({:pattern, _}, _), do: {0.0, 0.0, 0.0}
  def to_rgb(cs, comps), do: to_rgb(cs, pad(comps, components(cs)))

  defp pad(list, n) when length(list) >= n, do: list
  defp pad(list, n), do: list ++ List.duplicate(0, n - length(list))

  defp gamma(v) do
    v = if v <= 0.0031308, do: 12.92 * v, else: 1.055 * :math.pow(max(v, 0), 1 / 2.4) - 0.055
    clamp(v)
  end

  defp clamp(v) when is_number(v), do: v |> max(0.0) |> min(1.0) |> Kernel./(1)
  defp clamp(_), do: 0.0

  @doc "Default `/Decode` ranges for an image in this space with `bpc` bits."
  @spec default_decode(t(), pos_integer()) :: [number()]
  def default_decode({:indexed, _, _, _}, bpc), do: [0, :math.pow(2, bpc) - 1]
  def default_decode({:lab, _, [a0, a1, b0, b1 | _]}, _), do: [0, 100, a0, a1, b0, b1]
  def default_decode(cs, _), do: List.flatten(List.duplicate([0, 1], components(cs)))

  @doc "Hex CSS color for `{r, g, b}`."
  @spec hex({number(), number(), number()}) :: String.t()
  def hex({r, g, b}) do
    "#" <> Base.encode16(<<round(r * 255), round(g * 255), round(b * 255)>>, case: :lower)
  end
end
