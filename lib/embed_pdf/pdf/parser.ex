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

  # Arrays and dictionaries nested deeper than this are not followed: the
  # opening delimiter reads as a stray keyword and is dropped.
  @max_depth 500

  # Integers saturate at 20 digits (enough for any 64-bit value); the digits
  # beyond are skipped, so a long run of digits costs one pass and no bignum.
  @max_int 99_999_999_999_999_999_999
  @int_room 9_999_999_999_999_999_999

  # fractional digits beyond these cannot change a float (and 10^309 overflows)
  @max_frac_digits 300

  # what is read of a number written in an odd form (`--5`, `1.2.3`, ...)
  @max_number_chars 512

  # tokens longer than this are no longer gathered byte by byte
  @short_token 256

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
      rest -> do_value(rest, refs?, 0)
    end
  end

  defp do_value(<<"<<", rest::binary>>, refs?, depth) when depth < @max_depth,
    do: parse_dict(rest, refs?, %{}, depth + 1)

  defp do_value(<<"<<", rest::binary>>, _, _), do: {{:keyword, "<<"}, rest}
  defp do_value(<<"<", rest::binary>>, _, _), do: parse_hex_string(rest)
  defp do_value(<<"(", rest::binary>>, _, _), do: parse_literal_string(rest, 0, [])

  defp do_value(<<"[", rest::binary>>, refs?, depth) when depth < @max_depth,
    do: parse_array(rest, refs?, [], depth + 1)

  defp do_value(<<"[", rest::binary>>, _, _), do: {{:keyword, "["}, rest}
  defp do_value(<<"/", rest::binary>>, _, _), do: parse_name(rest)

  defp do_value(<<c, _::binary>> = input, refs?, _depth)
       when is_digit(c) or c in [?+, ?-, ?.] do
    {num, rest} = parse_number(input)

    if refs? and is_integer(num) and num >= 0 do
      maybe_ref(num, rest)
    else
      {num, rest}
    end
  end

  # stray closing delimiters are skipped one byte at a time
  defp do_value(<<c, rest::binary>>, _, _) when c in [?), ?>, ?], ?}, ?{],
    do: {{:keyword, <<c>>}, rest}

  defp do_value(input, _, _) do
    {word, rest} = take_regular(input, [], 0)

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
  def take_regular(input, acc), do: take_regular(input, acc, 0)

  # A token is gathered byte by byte, the fast way for the few bytes tokens
  # have; one that keeps going is measured and cut out in one piece instead,
  # so a token of any length costs its size and not a list cell per byte.
  defp take_regular(<<c, rest::binary>>, acc, n)
       when not is_ws(c) and not is_delim(c) and n < @short_token,
       do: take_regular(rest, [c | acc], n + 1)

  defp take_regular(rest, acc, n) when n < @short_token,
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_regular(input, acc, _n) do
    len = regular_len(input, 0)
    <<tail::binary-size(len), rest::binary>> = input
    {IO.iodata_to_binary([Enum.reverse(acc), tail]), rest}
  end

  defp regular_len(<<c, rest::binary>>, n) when not is_ws(c) and not is_delim(c),
    do: regular_len(rest, n + 1)

  defp regular_len(_rest, n), do: n

  # ---------------------------------------------------------------- numbers

  @doc "Parses a PDF number, tolerating forms such as `--5`, `.5`, `5.` and `1.2.3`."
  @spec parse_number(binary()) :: {number(), binary()}
  def parse_number(input) do
    case fast_number(input) do
      {:ok, n, rest} ->
        {n, rest}

      :slow ->
        {token, rest} = take_number_chars(input)
        {to_number(token), rest}
    end
  end

  # one pass over the common forms: [+-]digits[.digits]
  defp fast_number(<<?-, rest::binary>>), do: int_digits(rest, -1, 0, 0)
  defp fast_number(<<?+, rest::binary>>), do: int_digits(rest, 1, 0, 0)
  defp fast_number(input), do: int_digits(input, 1, 0, 0)

  # the first 18 digits cannot pass the limit (and need no bignum to check)
  defp int_digits(<<d, rest::binary>>, sign, acc, n) when is_digit(d) and n < 18,
    do: int_digits(rest, sign, acc * 10 + (d - ?0), n + 1)

  defp int_digits(<<d, rest::binary>>, sign, acc, n) when is_digit(d) and acc <= @int_room,
    do: int_digits(rest, sign, acc * 10 + (d - ?0), n + 1)

  # too many digits: saturate and skip the rest of the run
  defp int_digits(<<d, rest::binary>>, sign, _acc, n) when is_digit(d),
    do: int_digits(skip_digits(rest), sign, @max_int, n + 1)

  defp int_digits(<<?., rest::binary>>, sign, acc, n), do: frac_digits(rest, sign, acc, 0, 0, n)
  defp int_digits(_rest, _sign, _acc, 0), do: :slow

  defp int_digits(rest, sign, acc, _n) do
    if odd_next?(rest), do: :slow, else: {:ok, sign * acc, rest}
  end

  defp frac_digits(<<d, rest::binary>>, sign, int, frac, fl, n) when is_digit(d) and fl < 15,
    do: frac_digits(rest, sign, int, frac * 10 + (d - ?0), fl + 1, n)

  defp frac_digits(<<d, _::binary>>, _sign, _int, _frac, _fl, _n) when is_digit(d), do: :slow

  defp frac_digits(rest, sign, int, frac, fl, n) do
    if n + fl == 0 or odd_next?(rest),
      do: :slow,
      else: {:ok, sign * (int + frac / pow10(fl)), rest}
  end

  defp skip_digits(<<d, rest::binary>>) when is_digit(d), do: skip_digits(rest)
  defp skip_digits(rest), do: rest

  defp odd_next?(<<c, _::binary>>) when c in [?+, ?-, ?.], do: true
  defp odd_next?(_), do: false

  @pow10 List.to_tuple(for i <- 0..15, do: :math.pow(10, i))
  defp pow10(n), do: elem(@pow10, n)

  defp take_number_chars(input) do
    n = number_len(input, 0)
    <<token::binary-size(n), rest::binary>> = input
    {token, rest}
  end

  defp number_len(<<c, rest::binary>>, n) when is_digit(c) or c in [?+, ?-, ?.],
    do: number_len(rest, n + 1)

  defp number_len(_rest, n), do: n

  @doc false
  # only the start of an absurdly long token is looked at
  def to_number(token) when byte_size(token) > @max_number_chars,
    do: token |> binary_part(0, @max_number_chars) |> to_number()

  def to_number(token) do
    {sign, digits} = strip_signs(token, 1)

    case String.split(digits, ".", parts: 2) do
      [int] ->
        sign * parse_int(int)

      [int, frac] ->
        frac = frac |> String.replace(".", "") |> String.replace(~r/[^0-9]/, "")
        frac = binary_part(frac, 0, min(byte_size(frac), @max_frac_digits))
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

  defp parse_int(s) do
    case String.trim_leading(s, "0") do
      "" -> 0
      digits when byte_size(digits) > 20 -> @max_int
      digits -> String.to_integer(digits)
    end
  end

  # ---------------------------------------------------------------- names

  # `#xx` escapes are undone in names up to this long
  @max_escaped_name 65_536

  defp parse_name(input) do
    {n, escaped?} = name_len(input, 0, false)
    <<raw::binary-size(n), rest::binary>> = input

    name =
      if escaped? and n <= @max_escaped_name,
        do: unescape_name(raw, []),
        else: :binary.copy(raw)

    {name, rest}
  end

  defp name_len(<<?#, rest::binary>>, n, _escaped?), do: name_len(rest, n + 1, true)

  defp name_len(<<c, rest::binary>>, n, escaped?) when not is_ws(c) and not is_delim(c),
    do: name_len(rest, n + 1, escaped?)

  defp name_len(_rest, n, escaped?), do: {n, escaped?}

  defp unescape_name(<<?#, a, b, rest::binary>>, acc) when is_hex(a) and is_hex(b),
    do: unescape_name(rest, [String.to_integer(<<a, b>>, 16) | acc])

  defp unescape_name(<<c, rest::binary>>, acc), do: unescape_name(rest, [c | acc])
  defp unescape_name(<<>>, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  # ---------------------------------------------------------------- strings

  # up to the first `>` (or the end); anything that is not a hex digit is
  # skipped, and an odd last digit is followed by 0
  defp parse_hex_string(input) do
    {body, rest} =
      case :binary.match(input, ">") do
        {pos, 1} ->
          {binary_part(input, 0, pos), binary_part(input, pos + 1, byte_size(input) - pos - 1)}

        :nomatch ->
          {input, <<>>}
      end

    {{:string, hex_to_bin(body)}, rest}
  end

  defp hex_to_bin(body) do
    case Base.decode16(body, case: :mixed) do
      {:ok, bytes} ->
        bytes

      :error ->
        digits = for <<c <- body>>, is_hex(c), into: <<>>, do: <<c>>
        digits = if rem(byte_size(digits), 2) == 1, do: digits <> "0", else: digits
        Base.decode16!(digits, case: :mixed)
    end
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

  # a run of ordinary bytes goes in as one piece
  defp parse_literal_string(input, depth, acc) do
    n = plain_len(input, 0)
    <<run::binary-size(n), rest::binary>> = input
    parse_literal_string(rest, depth, [run | acc])
  end

  defp plain_len(<<c, rest::binary>>, n) when c not in [?(, ?), ?\\, ?\r],
    do: plain_len(rest, n + 1)

  defp plain_len(_rest, n), do: n

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

  defp parse_array(input, refs?, acc, depth) do
    case skip_ws(input) do
      <<"]", rest::binary>> ->
        {Enum.reverse(acc), rest}

      <<>> ->
        {Enum.reverse(acc), <<>>}

      rest ->
        case do_value(rest, refs?, depth) do
          # a stray keyword inside an array (e.g. a broken `R`) is dropped
          {{:keyword, _kw}, rest2} ->
            parse_array(rest2, refs?, acc, depth)

          {value, rest2} ->
            parse_array(rest2, refs?, [value | acc], depth)
        end
    end
  end

  defp parse_dict(input, refs?, acc, depth) do
    case skip_ws(input) do
      <<">>", rest::binary>> ->
        {acc, rest}

      <<>> ->
        {acc, <<>>}

      <<"/", rest::binary>> ->
        {key, rest} = parse_name(rest)

        case skip_ws(rest) do
          <<">>", _::binary>> = r ->
            parse_dict(r, refs?, acc, depth)

          <<"/", _::binary>> = r ->
            # a key immediately followed by a name is a key with that name value
            {value, r2} = do_value(r, refs?, depth)
            parse_dict(r2, refs?, Map.put(acc, key, value), depth)

          <<>> ->
            {acc, <<>>}

          r ->
            case do_value(r, refs?, depth) do
              {{:keyword, kw}, _r2} when kw in ["endobj", "stream", "obj"] ->
                # truncated dictionary: stop here and leave the keyword
                # (`r` starts with it, so nothing is copied)
                {acc, r}

              {{:keyword, _}, r2} ->
                parse_dict(r2, refs?, acc, depth)

              {nil, r2} ->
                parse_dict(r2, refs?, acc, depth)

              {value, r2} ->
                parse_dict(r2, refs?, Map.put(acc, key, value), depth)
            end
        end

      rest ->
        # junk inside a dictionary: skip a token
        case do_value(rest, refs?, depth) do
          {{:keyword, "endobj"}, _} -> {acc, rest}
          {_, rest2} -> parse_dict(rest2, refs?, acc, depth)
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
    {result, _consumed} = parse_indirect_consumed(input, length_fun)
    result
  end

  @doc """
  Like `parse_indirect/2`, also telling how many bytes of `input` were read
  to get there (a stream without `endstream` reads to the end).
  """
  @spec parse_indirect_consumed(binary(), (term() -> integer() | nil)) ::
          {{:ok, non_neg_integer(), non_neg_integer(), term()} | :error, non_neg_integer()}
  def parse_indirect_consumed(input, length_fun \\ fn _ -> nil end) do
    size = byte_size(input)

    case indirect_header(input) do
      {:ok, num, gen, rest} ->
        case parse_value(rest) do
          :eof ->
            {{:ok, num, gen, nil}, size}

          {{:keyword, "endobj"}, rest} ->
            {{:ok, num, gen, nil}, size - byte_size(rest)}

          {value, rest} ->
            {value, rest} = maybe_stream(value, rest, length_fun)
            {{:ok, num, gen, value}, size - byte_size(rest)}
        end

      {:error, rest} ->
        {:error, size - byte_size(rest)}
    end
  end

  @doc """
  `parse_indirect/2` within a budget of bytes: only the first `budget` bytes
  of `input` are looked at, and what was read is taken off the budget.
  Returns `{result, budget_left}`.

  Callers that parse many objects out of one file share a budget between
  them, so objects that overlap (or streams that never end) cannot make the
  total work grow faster than the file.
  """
  @spec parse_indirect_within(binary(), (term() -> integer() | nil), integer()) ::
          {{:ok, non_neg_integer(), non_neg_integer(), term()} | :error, integer()}
  def parse_indirect_within(_input, _length_fun, budget) when budget <= 0, do: {:error, budget}

  def parse_indirect_within(input, length_fun, budget) do
    window = if byte_size(input) > budget, do: binary_part(input, 0, budget), else: input
    {result, consumed} = parse_indirect_consumed(window, length_fun)
    {result, budget - max(consumed, 1)}
  end

  @doc "Reads `N G obj`; returns `{:ok, num, gen, rest}` or `{:error, rest_where_it_stopped}`."
  @spec indirect_header(binary()) ::
          {:ok, non_neg_integer(), non_neg_integer(), binary()} | {:error, binary()}
  def indirect_header(input) do
    r0 = skip_ws(input)

    case parse_number_strict(r0) do
      {num, r1} when is_integer(num) ->
        r2 = skip_ws(r1)

        case parse_number_strict(r2) do
          {gen, r3} when is_integer(gen) ->
            case skip_ws(r3) do
              <<"obj", rest::binary>> -> {:ok, num, gen, rest}
              r4 -> {:error, r4}
            end

          _ ->
            {:error, r2}
        end

      _ ->
        {:error, r0}
    end
  end

  defp parse_number_strict(<<c, _::binary>> = input) when is_digit(c), do: parse_number(input)
  defp parse_number_strict(_), do: :error

  # returns the value and the input left after it
  defp maybe_stream(dict, rest, length_fun) when is_map(dict) do
    case skip_ws(rest) do
      <<"stream", after_kw::binary>> ->
        data_start = skip_stream_eol(after_kw)
        declared = declared_length(dict["Length"], length_fun)
        {raw, rest} = take_stream_data(data_start, declared)
        {%Stream{dict: dict, raw: raw}, rest}

      rest ->
        {dict, rest}
    end
  end

  defp maybe_stream(value, rest, _length_fun), do: {value, rest}

  defp skip_stream_eol(<<"\r\n", rest::binary>>), do: rest
  defp skip_stream_eol(<<"\n", rest::binary>>), do: rest
  defp skip_stream_eol(<<"\r", rest::binary>>), do: rest
  # some writers put spaces before the EOL
  defp skip_stream_eol(<<" ", rest::binary>>), do: skip_stream_eol(rest)
  defp skip_stream_eol(rest), do: rest

  defp declared_length(len, _fun) when is_integer(len) and len >= 0, do: len
  defp declared_length({:ref, _, _} = ref, fun), do: fun.(ref)
  defp declared_length(_, _), do: nil

  # returns the stream bytes and the input left after what was looked at
  defp take_stream_data(data, len) when is_integer(len) and len <= byte_size(data) do
    after_data = data |> binary_part(len, byte_size(data) - len) |> skip_ws()

    if String.starts_with?(after_data, "endstream") do
      {binary_part(data, 0, len), after_data}
    else
      {raw, rest} = scan_endstream(data)
      {raw, if(byte_size(after_data) < byte_size(rest), do: after_data, else: rest)}
    end
  end

  defp take_stream_data(data, _), do: scan_endstream(data)

  defp scan_endstream(data) do
    case :binary.match(data, "endstream") do
      {pos, len} ->
        {data |> binary_part(0, pos) |> trim_trailing_eol(),
         binary_part(data, pos + len, byte_size(data) - pos - len)}

      :nomatch ->
        {data, <<>>}
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
