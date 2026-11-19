defmodule EmbedPdf.Render.Function do
  @moduledoc """
  PDF functions (ISO 32000-1, 7.10): type 0 (sampled), 2 (exponential),
  3 (stitching) and 4 (PostScript calculator). Arrays of functions are
  evaluated one output each.
  """

  alias EmbedPdf.PDF.{Document, Stream}

  @doc "Parses a function object (or array of them) into an evaluable term."
  @spec parse(Document.t(), term()) :: term()
  def parse(doc, value) do
    case Document.resolve(doc, value) do
      list when is_list(list) -> {:array, Enum.map(list, &parse(doc, &1))}
      %Stream{dict: dict} = s -> parse_dict(doc, dict, s)
      %{} = dict -> parse_dict(doc, dict, nil)
      "Identity" -> :identity
      _ -> nil
    end
  end

  defp parse_dict(doc, dict, stream) do
    domain = Document.resolve(doc, dict["Domain"]) || [0, 1]
    range = Document.resolve(doc, dict["Range"])

    case Document.resolve(doc, dict["FunctionType"]) do
      2 ->
        c0 = Document.resolve(doc, dict["C0"]) || [0.0]
        c1 = Document.resolve(doc, dict["C1"]) || [1.0]
        n = Document.resolve(doc, dict["N"]) || 1
        {:exp, domain, range, c0, c1, n}

      3 ->
        funcs = (Document.resolve(doc, dict["Functions"]) || []) |> Enum.map(&parse(doc, &1))
        bounds = Document.resolve(doc, dict["Bounds"]) || []
        encode = Document.resolve(doc, dict["Encode"]) || []
        {:stitch, domain, range, funcs, bounds, encode}

      0 when stream != nil ->
        size = Document.resolve(doc, dict["Size"]) || [2]
        bps = Document.resolve(doc, dict["BitsPerSample"]) || 8
        encode = Document.resolve(doc, dict["Encode"]) || Enum.flat_map(size, &[0, &1 - 1])
        decode = Document.resolve(doc, dict["Decode"]) || range
        data = Document.stream_data(doc, stream) || <<>>
        {:sampled, domain, range, size, bps, encode, decode, data}

      4 when stream != nil ->
        code = Document.stream_data(doc, stream) || ""
        {:postscript, domain, range, EmbedPdf.Render.PostScript.parse(code)}

      _ ->
        nil
    end
  end

  @doc "Evaluates a function on a list of inputs, returning a list of outputs."
  @spec eval(term(), [number()]) :: [float()]
  def eval(nil, inputs), do: inputs
  def eval(:identity, inputs), do: inputs
  def eval({:array, funcs}, inputs), do: Enum.flat_map(funcs, &eval(&1, inputs))

  def eval({:exp, domain, range, c0, c1, n}, [x | _]) do
    x = clip(x, domain, 0)
    xn = if x < 0 and n != round(n), do: 0.0, else: :math.pow(x, n)

    Enum.zip(c0, c1)
    |> Enum.map(fn {a, b} -> a + xn * (b - a) end)
    |> clip_range(range)
  end

  def eval({:stitch, [d0, d1 | _] = domain, range, funcs, bounds, encode}, [x | _]) do
    x = clip(x, domain, 0)
    k = Enum.count(bounds, &(x >= &1))
    k = min(k, length(funcs) - 1)
    low = if k == 0, do: d0, else: Enum.at(bounds, k - 1)
    high = if k == length(bounds), do: d1, else: Enum.at(bounds, k)
    e0 = Enum.at(encode, 2 * k, 0)
    e1 = Enum.at(encode, 2 * k + 1, 1)
    t = if high == low, do: e0, else: e0 + (x - low) * (e1 - e0) / (high - low)

    case Enum.at(funcs, k) do
      nil -> [x]
      f -> f |> eval([t]) |> clip_range(range)
    end
  end

  def eval({:sampled, domain, range, size, bps, encode, decode, data}, inputs) do
    m = length(size)
    nout = div(length(range || [0, 1]), 2)
    max_sample = :math.pow(2, bps) - 1

    # nearest-sample lookup per input dimension (linear in the first)
    idx =
      inputs
      |> Enum.take(m)
      |> Enum.with_index()
      |> Enum.map(fn {x, i} ->
        x = clip(x, domain, i)
        d0 = Enum.at(domain, 2 * i, 0)
        d1 = Enum.at(domain, 2 * i + 1, 1)
        e0 = Enum.at(encode, 2 * i, 0)
        e1 = Enum.at(encode, 2 * i + 1, Enum.at(size, i) - 1)
        e = if d1 == d0, do: e0, else: e0 + (x - d0) * (e1 - e0) / (d1 - d0)
        e |> max(0) |> min(Enum.at(size, i) - 1)
      end)

    {offset, _} =
      Enum.reduce(Enum.with_index(idx), {0, 1}, fn {e, i}, {off, stride} ->
        {off + trunc(e) * stride, stride * Enum.at(size, i)}
      end)

    frac =
      case idx do
        [e | _] -> e - trunc(e)
        _ -> 0
      end

    s0 = samples(data, offset, nout, bps)

    s =
      if frac > 0 and trunc(hd(idx)) + 1 < hd(size) do
        s1 = samples(data, offset + 1, nout, bps)
        Enum.zip(s0, s1) |> Enum.map(fn {a, b} -> a + (b - a) * frac end)
      else
        s0
      end

    decode = decode || range || []

    s
    |> Enum.with_index()
    |> Enum.map(fn {v, j} ->
      d0 = Enum.at(decode, 2 * j, 0)
      d1 = Enum.at(decode, 2 * j + 1, 1)
      d0 + v * (d1 - d0) / max_sample
    end)
    |> clip_range(range)
  end

  def eval({:postscript, domain, range, program}, inputs) do
    inputs = inputs |> Enum.with_index() |> Enum.map(fn {x, i} -> clip(x, domain, i) end)
    program |> EmbedPdf.Render.PostScript.run(inputs) |> clip_range(range)
  end

  def eval(_, inputs), do: inputs

  defp samples(data, index, nout, bps) do
    for j <- 0..(nout - 1)//1 do
      bit = (index * nout + j) * bps
      byte = div(bit, 8)
      shift = rem(bit, 8)

      if byte + div(bps + shift + 7, 8) <= byte_size(data) do
        <<_::size(byte)-unit(8), _::size(shift), v::size(bps), _::bitstring>> = data
        v
      else
        0
      end
    end
  end

  defp clip(x, domain, i) do
    lo = Enum.at(domain, 2 * i, 0)
    hi = Enum.at(domain, 2 * i + 1, 1)
    (x || 0) |> max(lo) |> min(hi)
  end

  defp clip_range(values, nil), do: Enum.map(values, &(&1 / 1))

  defp clip_range(values, range) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      lo = Enum.at(range, 2 * i)
      hi = Enum.at(range, 2 * i + 1)
      if lo && hi, do: (v |> max(lo) |> min(hi)) / 1, else: v / 1
    end)
  end
end
