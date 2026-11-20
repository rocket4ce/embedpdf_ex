defmodule EmbedPdf.Render.Function do
  @moduledoc """
  PDF functions (ISO 32000-1, 7.10): type 0 (sampled), 2 (exponential),
  3 (stitching) and 4 (PostScript calculator). Arrays of functions are
  evaluated one output each.

  A function may nest others (arrays, stitching) 8 levels deep and hold
  1024 functions in all, counting one used twice as two; whatever goes
  beyond, or refers back to a function it is part of, is left out and
  passes its input through.
  """

  alias EmbedPdf.PDF.{Document, Stream}
  alias EmbedPdf.Render.PostScript

  @max_depth 8
  @max_functions 1024
  # numbers kept from a range or a color: two per output, and a DeviceN
  # space, the largest, has 32
  @max_values 64

  @doc "Parses a function object (or array of them) into an evaluable term."
  @spec parse(Document.t(), term()) :: term()
  def parse(doc, value) do
    {func, _acc} = parse(doc, value, 0, MapSet.new(), {@max_functions, %{}})
    func
  end

  # `seen`: the objects this function is nested in. `acc` is `{left, leaves}`:
  # the functions that may still be added (whatever stands where a function
  # should counts as one), and the sampled and calculator functions read so
  # far by object number (their streams are decoded once).
  # Returns {function, acc}.
  defp parse(_doc, _value, _depth, _seen, {left, _} = acc) when left <= 0, do: {nil, acc}

  defp parse(_doc, _value, depth, _seen, {left, leaves}) when depth > @max_depth,
    do: {nil, {left - 1, leaves}}

  defp parse(doc, {:ref, n, _} = ref, depth, seen, {left, leaves}) do
    acc = {left - 1, leaves}

    if MapSet.member?(seen, n),
      do: {nil, acc},
      else: parse_value(doc, Document.resolve(doc, ref), n, depth, MapSet.put(seen, n), acc)
  end

  defp parse(doc, value, depth, seen, {left, leaves}),
    do: parse_value(doc, value, nil, depth, seen, {left - 1, leaves})

  defp parse_value(doc, value, id, depth, seen, acc) do
    case value do
      list when is_list(list) ->
        {funcs, acc} = parse_list(doc, list, depth + 1, seen, acc)
        {{:array, funcs}, acc}

      %Stream{dict: dict} = s ->
        parse_dict(doc, dict, s, id, depth, seen, acc)

      %{} = dict ->
        parse_dict(doc, dict, nil, id, depth, seen, acc)

      "Identity" ->
        {:identity, acc}

      _ ->
        {nil, acc}
    end
  end

  # stops at the first function that no longer fits
  defp parse_list(doc, list, depth, seen, acc) do
    {funcs, acc} =
      Enum.reduce_while(list, {[], acc}, fn
        _item, {_funcs, {left, _}} = result when left <= 0 ->
          {:halt, result}

        item, {funcs, acc} ->
          {func, acc} = parse(doc, item, depth, seen, acc)
          {:cont, {[func | funcs], acc}}
      end)

    {Enum.reverse(funcs), acc}
  end

  defp parse_dict(doc, dict, stream, id, depth, seen, {left, leaves} = acc) do
    case Document.resolve(doc, dict["FunctionType"]) do
      2 ->
        {domain, range} = domain_range(doc, dict)
        c0 = values(Document.resolve(doc, dict["C0"])) || [0.0]
        c1 = values(Document.resolve(doc, dict["C1"])) || [1.0]
        n = Document.resolve(doc, dict["N"]) || 1
        {{:exp, domain, range, c0, c1, n}, acc}

      3 ->
        {domain, range} = domain_range(doc, dict)
        list = Document.resolve(doc, dict["Functions"]) || []
        {funcs, acc} = parse_list(doc, list, depth + 1, seen, acc)
        # one bound between two functions: there are never more than those
        bounds = Enum.take(Document.resolve(doc, dict["Bounds"]) || [], @max_functions)
        encode = Document.resolve(doc, dict["Encode"]) || []
        {{:stitch, domain, range, funcs, bounds, encode}, acc}

      type when type in [0, 4] and stream != nil ->
        case leaves do
          %{^id => func} when id != nil ->
            {func, acc}

          _ ->
            func = leaf(doc, type, dict, stream)
            {func, {left, if(id, do: Map.put(leaves, id, func), else: leaves)}}
        end

      _ ->
        {nil, acc}
    end
  end

  defp leaf(doc, 0, dict, stream) do
    {domain, range} = domain_range(doc, dict)
    size = Document.resolve(doc, dict["Size"]) || [2]
    bps = Document.resolve(doc, dict["BitsPerSample"]) || 8
    encode = Document.resolve(doc, dict["Encode"]) || Enum.flat_map(size, &[0, &1 - 1])
    decode = Document.resolve(doc, dict["Decode"]) || range
    data = Document.stream_data(doc, stream) || <<>>
    {:sampled, domain, range, size, bps, encode, decode, data}
  end

  defp leaf(doc, 4, dict, stream) do
    {domain, range} = domain_range(doc, dict)
    code = Document.stream_data(doc, stream) || ""
    {:postscript, domain, range, PostScript.parse(code)}
  end

  defp domain_range(doc, dict) do
    {Document.resolve(doc, dict["Domain"]) || [0, 1],
     values(Document.resolve(doc, dict["Range"]))}
  end

  defp values(list) when is_list(list), do: Enum.take(list, @max_values)
  defp values(other), do: other

  @doc """
  An upper bound on the work one `eval/2` takes, in calculator steps (what
  is not a calculator program counts as 16).
  """
  @spec cost(term()) :: pos_integer()
  def cost({:array, funcs}), do: Enum.reduce(funcs, 16, &(cost(&1) + &2))

  def cost({:stitch, _, _, funcs, bounds, _}),
    do: 16 + length(funcs) + length(bounds) + Enum.reduce(funcs, 0, &max(cost(&1), &2))

  def cost({:postscript, _, _, program}), do: 16 + PostScript.steps(program)
  def cost(_), do: 16

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
