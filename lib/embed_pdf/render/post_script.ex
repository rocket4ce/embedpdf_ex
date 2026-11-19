defmodule EmbedPdf.Render.PostScript do
  @moduledoc "The PostScript calculator subset used by type 4 functions (ISO 32000-1, 7.10.5)."

  alias EmbedPdf.PDF.Parser

  @doc "Parses `{ ... }` program text into nested lists of numbers, operators and `{:if, a}` / `{:ifelse, a, b}`."
  @spec parse(binary()) :: list()
  def parse(code) do
    tokens = tokenize(code, [])

    case tokens do
      [{:open} | rest] -> rest |> block([]) |> elem(0)
      _ -> []
    end
  end

  defp tokenize(code, acc) do
    case Parser.skip_ws(code) do
      <<>> ->
        Enum.reverse(acc)

      <<"{", rest::binary>> ->
        tokenize(rest, [{:open} | acc])

      <<"}", rest::binary>> ->
        tokenize(rest, [{:close} | acc])

      rest ->
        case Parser.parse_value(rest, refs: false) do
          {{:keyword, kw}, r} -> tokenize(r, [kw | acc])
          {n, r} when is_number(n) -> tokenize(r, [n | acc])
          {_, r} -> tokenize(r, acc)
          :eof -> Enum.reverse(acc)
        end
    end
  end

  defp block([], acc), do: {Enum.reverse(acc), []}
  defp block([{:close} | rest], acc), do: {Enum.reverse(acc), rest}

  defp block([{:open} | rest], acc) do
    {a, rest} = block(rest, [])

    case rest do
      [{:open} | rest2] ->
        {b, rest3} = block(rest2, [])

        case rest3 do
          ["ifelse" | rest4] -> block(rest4, [{:ifelse, a, b} | acc])
          _ -> block(rest3, acc)
        end

      ["if" | rest2] ->
        block(rest2, [{:if, a} | acc])

      _ ->
        block(rest, acc)
    end
  end

  defp block([tok | rest], acc), do: block(rest, [tok | acc])

  @doc "Runs a parsed program with `inputs` on the stack; returns the stack bottom-up."
  @spec run(list(), [number()]) :: [float()]
  def run(program, inputs) do
    stack = Enum.reverse(inputs)

    program
    |> exec(stack)
    |> Enum.reverse()
    |> Enum.map(fn
      true -> 1.0
      false -> 0.0
      v -> v / 1
    end)
  rescue
    _ -> inputs
  end

  defp exec([], stack), do: stack

  defp exec([op | rest], stack), do: exec(rest, step(op, stack))

  defp step(n, s) when is_number(n), do: [n | s]
  defp step({:if, a}, [c | s]), do: if(truthy(c), do: exec(a, s), else: s)
  defp step({:ifelse, a, b}, [c | s]), do: if(truthy(c), do: exec(a, s), else: exec(b, s))
  defp step("true", s), do: [true | s]
  defp step("false", s), do: [false | s]
  defp step("add", [b, a | s]), do: [a + b | s]
  defp step("sub", [b, a | s]), do: [a - b | s]
  defp step("mul", [b, a | s]), do: [a * b | s]
  defp step("div", [b, a | s]), do: [if(b == 0, do: 0.0, else: a / b) | s]
  defp step("idiv", [b, a | s]), do: [if(b == 0, do: 0, else: div(trunc(a), trunc(b))) | s]
  defp step("mod", [b, a | s]), do: [if(b == 0, do: 0, else: rem(trunc(a), trunc(b))) | s]
  defp step("neg", [a | s]), do: [-a | s]
  defp step("abs", [a | s]), do: [abs(a) | s]
  defp step("ceiling", [a | s]), do: [Float.ceil(a / 1) | s]
  defp step("floor", [a | s]), do: [Float.floor(a / 1) | s]
  defp step("round", [a | s]), do: [Float.round(a / 1) | s]
  defp step("truncate", [a | s]), do: [trunc(a) / 1 | s]
  defp step("sqrt", [a | s]), do: [:math.sqrt(max(a, 0)) | s]
  defp step("sin", [a | s]), do: [:math.sin(a * :math.pi() / 180) | s]
  defp step("cos", [a | s]), do: [:math.cos(a * :math.pi() / 180) | s]

  defp step("atan", [b, a | s]) do
    deg = :math.atan2(a, b) * 180 / :math.pi()
    [if(deg < 0, do: deg + 360, else: deg) | s]
  end

  defp step("exp", [b, a | s]), do: [:math.pow(a, b) | s]
  defp step("ln", [a | s]), do: [:math.log(max(a, 1.0e-30)) | s]
  defp step("log", [a | s]), do: [:math.log10(max(a, 1.0e-30)) | s]
  defp step("cvi", [a | s]), do: [trunc(a) | s]
  defp step("cvr", [a | s]), do: [a / 1 | s]
  defp step("dup", [a | s]), do: [a, a | s]
  defp step("pop", [_ | s]), do: s
  defp step("exch", [b, a | s]), do: [a, b | s]

  defp step("copy", [n | s]) do
    n = trunc(n)
    Enum.take(s, n) ++ s
  end

  defp step("index", [n | s]), do: [Enum.at(s, trunc(n)) | s]

  defp step("roll", [j, n | s]) do
    n = trunc(n)
    j = trunc(j)
    {top, rest} = Enum.split(s, n)

    if n == 0 do
      rest
    else
      # stack top is the list head: rolling by j moves elements toward the top
      top = Enum.reverse(top)
      k = Integer.mod(j, n)
      rolled = Enum.drop(top, n - k) ++ Enum.take(top, n - k)
      Enum.reverse(rolled) ++ rest
    end
  end

  defp step("eq", [b, a | s]), do: [a == b | s]
  defp step("ne", [b, a | s]), do: [a != b | s]
  defp step("gt", [b, a | s]), do: [a > b | s]
  defp step("ge", [b, a | s]), do: [a >= b | s]
  defp step("lt", [b, a | s]), do: [a < b | s]
  defp step("le", [b, a | s]), do: [a <= b | s]
  defp step("and", [b, a | s]), do: [bool_op(a, b, &Kernel.and/2, &Bitwise.band/2) | s]
  defp step("or", [b, a | s]), do: [bool_op(a, b, &Kernel.or/2, &Bitwise.bor/2) | s]
  defp step("xor", [b, a | s]), do: [bool_op(a, b, &(&1 != &2), &Bitwise.bxor/2) | s]
  defp step("not", [a | s]) when is_boolean(a), do: [not a | s]
  defp step("not", [a | s]), do: [Bitwise.bnot(trunc(a)) | s]

  defp step("bitshift", [b, a | s]),
    do: [
      if(b >= 0, do: Bitwise.bsl(trunc(a), trunc(b)), else: Bitwise.bsr(trunc(a), -trunc(b))) | s
    ]

  defp step(_, s), do: s

  defp bool_op(a, b, bf, _) when is_boolean(a) and is_boolean(b), do: bf.(a, b)
  defp bool_op(a, b, _, nf), do: nf.(trunc(num(a)), trunc(num(b)))

  defp num(true), do: 1
  defp num(false), do: 0
  defp num(n), do: n

  defp truthy(true), do: true
  defp truthy(false), do: false
  defp truthy(n), do: n != 0
end
