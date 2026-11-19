defmodule EmbedPdf.PDF.Parser do
  @moduledoc """
  Tokenizer and object parser for PDF syntax (ISO 32000-1, section 7.3).

  Every function takes the remaining input as a binary and returns the value
  together with the rest, so positions are `byte_size(data) - byte_size(rest)`.
  Parsing is tolerant: malformed input yields the best value it can instead
  of raising, the way viewers have to treat real-world files.
  """

  alias EmbedPdf.PDF.Stream

  @ws [0, 9, 10, 12, 13, 32]
  @delims ~c"()<>[]{}/%"

  defguard is_ws(c) when c in @ws
  defguard is_delim(c) when c in @delims
  defguard is_digit(c) when c in ?0..?9
  defguard is_hex(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  @doc "Skips whitespace and comments."
  @spec skip_ws(binary()) :: binary()
  def skip_ws(<<c, rest::binary>>) when is_ws(c), do: skip_ws(rest)
  def skip_ws(<<?%, rest::binary>>), do: rest |> skip_comment() |> skip_ws()
  def skip_ws(rest), do: rest

  defp skip_comment(<<c, rest::binary>>) when c in [10, 13], do: rest
  defp skip_comment(<<_, rest::binary>>), do: skip_comment(rest)
  defp skip_comment(<<>>), do: <<>>

  @doc """
  Parses one value. With `refs: false` (content streams) `1 0 R` is not
  folded into a reference. Bare keywords come back as `{:keyword, word}`.
  """
  @spec parse_value(binary(), keyword()) :: {term(), binary()} | :eof
  def parse_value(input, opts \\ []) do
    refs? = Keyword.get(opts, :refs, true)

    case skip_ws(input) do
      <<>> -> :eof
      rest -> do_value(rest, refs?)
    end
  end

  defp do_value(<<"<<", rest::binary>>, refs?), do: parse_dict(rest, refs?, %{})
  defp do_value(<<"<", rest::binary>>, _), do: parse_hex_string(rest, [])
  defp do_value(<<"(", rest::binary>>, _), do: parse_literal_string(rest, 0, [])
  defp do_value(<<"[", rest::binary>>, refs?), do: parse_array(rest, refs?, [])
  defp do_value(<<"/", rest::binary>>, _), do: parse_name(rest, [])

  defp do_value(<<c, _::binary>> = input, refs?) when is_digit(c) or c in [?+, ?-, ?.] do
    {num, rest} = parse_number(input)

    if refs? and is_integer(num) and num >= 0 do
      maybe_ref(num, rest)
    else
      {num, rest}
    end
  end

  # stray closing delimiters are skipped one byte at a time
  defp do_value(<<c, rest::binary>>, _) when c in [?), ?>, ?], ?}, ?{],
    do: {{:keyword, <<c>>}, rest}

  defp do_value(input, _) do
    {word, rest} = take_regular(input, [])

    case word do
      "true" -> {true, rest}
      "false" -> {false, rest}
      "null" -> {nil, rest}
      "" -> {{:keyword, ""}, binary_part(input, 1, byte_size(input) - 1)}
      other -> {{:keyword, other}, rest}
    end
  end

  defp maybe_ref(num, rest) do
    with <<c, _::binary>> = r1 when is_ws(c) <- rest,
         <<d, _::binary>> = r2 when is_digit(d) <- skip_ws(r1),
         {gen, r3} when is_integer(gen) <- parse_number(r2),
         <<e, _::binary>> = r4 when is_ws(e) <- r3,
         <<"R", r5::binary>> <- skip_ws(r4),
         true <- r5 == <<>> or regular_end?(r5) do
      {{:ref, num, gen}, r5}
    else
      _ -> {num, rest}
    end
  end

  defp regular_end?(<<c, _::binary>>), do: is_ws(c) or is_delim(c)

  @doc "Reads a run of regular (non-whitespace, non-delimiter) characters."
  @spec take_regular(binary(), list()) :: {binary(), binary()}
  def take_regular(<<c, rest::binary>>, acc) when not is_ws(c) and not is_delim(c),
    do: take_regular(rest, [c | acc])

  def take_regular(rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  # ---------------------------------------------------------------- numbers

  @doc "Parses a PDF number, tolerating forms such as `--5`, `.5`, `5.` and `1.2.3`."
  @spec parse_number(binary()) :: {number(), binary()}
  def parse_number(input) do
    {token, rest} = take_number_chars(input, [])
    {to_number(token), rest}
  end

  defp take_number_chars(<<c, rest::binary>>, acc) when is_digit(c) or c in [?+, ?-, ?.],
    do: take_number_chars(rest, [c | acc])

  defp take_number_chars(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  @doc false
  def to_number(token) do
    {sign, digits} = strip_signs(token, 1)

    case String.split(digits, ".", parts: 2) do
      [int] ->
        sign * parse_int(int)

      [int, frac] ->
        frac = frac |> String.replace(".", "") |> String.replace(~r/[^0-9]/, "")
        int_part = parse_int(int)

        frac_part =
          if frac == "", do: 0.0, else: String.to_integer(frac) / :math.pow(10, byte_size(frac))

        sign * (int_part + frac_part)
    end
  end

  defp strip_signs(<<"-", rest::binary>>, sign), do: strip_signs(rest, -sign)
  defp strip_signs(<<"+", rest::binary>>, sign), do: strip_signs(rest, sign)
  defp strip_signs(rest, sign), do: {sign, String.replace(rest, ["-", "+"], "")}

  defp parse_int(""), do: 0
  defp parse_int(s), do: String.to_integer(s)

  # ---------------------------------------------------------------- names

  defp parse_name(<<?#, a, b, rest::binary>>, acc) when is_hex(a) and is_hex(b),
    do: parse_name(rest, [String.to_integer(<<a, b>>, 16) | acc])

  defp parse_name(<<c, rest::binary>>, acc) when not is_ws(c) and not is_delim(c),
    do: parse_name(rest, [c | acc])

  defp parse_name(rest, acc), do: {acc |> Enum.reverse() |> :erlang.list_to_binary(), rest}

  # ---------------------------------------------------------------- strings

  defp parse_hex_string(<<">", rest::binary>>, acc), do: {{:string, hex_to_bin(acc)}, rest}
  defp parse_hex_string(<<>>, acc), do: {{:string, hex_to_bin(acc)}, <<>>}

  defp parse_hex_string(<<c, rest::binary>>, acc)
       when c in ?0..?9 or c in ?a..?f or c in ?A..?F,
       do: parse_hex_string(rest, [c | acc])

  defp parse_hex_string(<<_, rest::binary>>, acc), do: parse_hex_string(rest, acc)

  defp hex_to_bin(acc) do
    digits = Enum.reverse(acc)
    digits = if rem(length(digits), 2) == 1, do: digits ++ [?0], else: digits
    digits |> List.to_string() |> Base.decode16!(case: :mixed)
  end

  defp parse_literal_string(<<>>, _depth, acc), do: {{:string, finish(acc)}, <<>>}

  defp parse_literal_string(<<")", rest::binary>>, 0, acc), do: {{:string, finish(acc)}, rest}

  defp parse_literal_string(<<")", rest::binary>>, depth, acc),
    do: parse_literal_string(rest, depth - 1, [?) | acc])

  defp parse_literal_string(<<"(", rest::binary>>, depth, acc),
    do: parse_literal_string(rest, depth + 1, [?( | acc])

  defp parse_literal_string(<<"\\", rest::binary>>, depth, acc) do
    case rest do
      <<"n", r::binary>> -> parse_literal_string(r, depth, [?\n | acc])
      <<"r", r::binary>> -> parse_literal_string(r, depth, [?\r | acc])
      <<"t", r::binary>> -> parse_literal_string(r, depth, [?\t | acc])
      <<"b", r::binary>> -> parse_literal_string(r, depth, [?\b | acc])
      <<"f", r::binary>> -> parse_literal_string(r, depth, [?\f | acc])
      <<"\r\n", r::binary>> -> parse_literal_string(r, depth, acc)
      <<"\r", r::binary>> -> parse_literal_string(r, depth, acc)
      <<"\n", r::binary>> -> parse_literal_string(r, depth, acc)
      <<a, _::binary>> when a in ?0..?7 -> octal(rest, depth, acc)
      <<c, r::binary>> -> parse_literal_string(r, depth, [c | acc])
      <<>> -> {{:string, finish(acc)}, <<>>}
    end
  end

  # a bare CR or CRLF inside a string reads as LF
  defp parse_literal_string(<<"\r\n", rest::binary>>, depth, acc),
    do: parse_literal_string(rest, depth, [?\n | acc])

  defp parse_literal_string(<<"\r", rest::binary>>, depth, acc),
    do: parse_literal_string(rest, depth, [?\n | acc])

  defp parse_literal_string(<<c, rest::binary>>, depth, acc),
    do: parse_literal_string(rest, depth, [c | acc])

  defp octal(input, depth, acc) do
    {digits, rest} = take_octal(input, [], 3)
    value = digits |> List.to_string() |> String.to_integer(8) |> Bitwise.band(0xFF)
    parse_literal_string(rest, depth, [value | acc])
  end

  defp take_octal(<<c, rest::binary>>, acc, n) when n > 0 and c in ?0..?7,
    do: take_octal(rest, acc ++ [c], n - 1)

  defp take_octal(rest, acc, _), do: {acc, rest}

  defp finish(acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  # ---------------------------------------------------------------- arrays & dicts

  defp parse_array(input, refs?, acc) do
    case skip_ws(input) do
      <<"]", rest::binary>> ->
        {Enum.reverse(acc), rest}

      <<>> ->
        {Enum.reverse(acc), <<>>}

      rest ->
        case do_value(rest, refs?) do
          # a stray keyword inside an array (e.g. a broken `R`) is dropped
          {{:keyword, _kw}, rest2} ->
            parse_array(rest2, refs?, acc)

          {value, rest2} ->
            parse_array(rest2, refs?, [value | acc])
        end
    end
  end

  defp parse_dict(input, refs?, acc) do
    case skip_ws(input) do
      <<">>", rest::binary>> ->
        {acc, rest}

      <<>> ->
        {acc, <<>>}

      <<"/", rest::binary>> ->
        {key, rest} = parse_name(rest, [])

        case skip_ws(rest) do
          <<">>", _::binary>> = r ->
            parse_dict(r, refs?, acc)

          <<"/", _::binary>> = r ->
            # a key immediately followed by a name is a key with that name value
            {value, r2} = do_value(r, refs?)
            parse_dict(r2, refs?, Map.put(acc, key, value))

          <<>> ->
            {acc, <<>>}

          r ->
            case do_value(r, refs?) do
              {{:keyword, kw}, r2} when kw in ["endobj", "stream", "obj"] ->
                # truncated dictionary: stop here and leave the keyword
                {acc, kw <> r2}

              {{:keyword, _}, r2} ->
                parse_dict(r2, refs?, acc)

              {nil, r2} ->
                parse_dict(r2, refs?, acc)

              {value, r2} ->
                parse_dict(r2, refs?, Map.put(acc, key, value))
            end
        end

      rest ->
        # junk inside a dictionary: skip a token
        case do_value(rest, refs?) do
          {{:keyword, "endobj"}, _} -> {acc, rest}
          {_, rest2} -> parse_dict(rest2, refs?, acc)
        end
    end
  end

  # ---------------------------------------------------------------- indirect objects

  @doc """
  Parses an indirect object `N G obj ... endobj` at the start of `input`.

  `length_fun` resolves a stream's `/Length` when it is an indirect reference;
  it gets the value and returns an integer or `nil`.
  Returns `{:ok, num, gen, value}` or `:error`.
  """
  @spec parse_indirect(binary(), (term() -> integer() | nil)) ::
          {:ok, non_neg_integer(), non_neg_integer(), term()} | :error
  def parse_indirect(input, length_fun \\ fn _ -> nil end) do
    with rest <- skip_ws(input),
         {num, rest} when is_integer(num) <- parse_number_strict(rest),
         {gen, rest} when is_integer(gen) <- parse_number_strict(skip_ws(rest)),
         <<"obj", rest::binary>> <- skip_ws(rest) do
      case parse_value(rest) do
        :eof ->
          {:ok, num, gen, nil}

        {{:keyword, "endobj"}, _} ->
          {:ok, num, gen, nil}

        {value, rest} ->
          {:ok, num, gen, maybe_stream(value, rest, length_fun)}
      end
    else
      _ -> :error
    end
  end

  defp parse_number_strict(<<c, _::binary>> = input) when is_digit(c), do: parse_number(input)
  defp parse_number_strict(_), do: :error

  defp maybe_stream(dict, rest, length_fun) when is_map(dict) do
    case skip_ws(rest) do
      <<"stream", after_kw::binary>> ->
        data_start = skip_stream_eol(after_kw)
        declared = declared_length(dict["Length"], length_fun)
        %Stream{dict: dict, raw: take_stream_data(data_start, declared)}

      _ ->
        dict
    end
  end

  defp maybe_stream(value, _rest, _length_fun), do: value

  defp skip_stream_eol(<<"\r\n", rest::binary>>), do: rest
  defp skip_stream_eol(<<"\n", rest::binary>>), do: rest
  defp skip_stream_eol(<<"\r", rest::binary>>), do: rest
  # some writers put spaces before the EOL
  defp skip_stream_eol(<<" ", rest::binary>>), do: skip_stream_eol(rest)
  defp skip_stream_eol(rest), do: rest

  defp declared_length(len, _fun) when is_integer(len) and len >= 0, do: len
  defp declared_length({:ref, _, _} = ref, fun), do: fun.(ref)
  defp declared_length(_, _), do: nil

  defp take_stream_data(data, len) when is_integer(len) and len <= byte_size(data) do
    after_data = binary_part(data, len, byte_size(data) - len)

    if after_data |> skip_ws() |> String.starts_with?("endstream") do
      binary_part(data, 0, len)
    else
      scan_endstream(data)
    end
  end

  defp take_stream_data(data, _), do: scan_endstream(data)

  defp scan_endstream(data) do
    case :binary.match(data, "endstream") do
      {pos, _} -> data |> binary_part(0, pos) |> trim_trailing_eol()
      :nomatch -> data
    end
  end

  defp trim_trailing_eol(data) do
    size = byte_size(data)

    cond do
      size >= 2 and binary_part(data, size - 2, 2) == "\r\n" ->
        binary_part(data, 0, size - 2)

      size >= 1 and binary_part(data, size - 1, 1) in ["\n", "\r"] ->
        binary_part(data, 0, size - 1)

      true ->
        data
    end
  end
end
