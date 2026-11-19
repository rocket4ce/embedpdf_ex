defmodule EmbedPdf.PDF.Crypt do
  @moduledoc """
  The PDF standard security handler (ISO 32000-2, 7.6.4): RC4 40–128 bit,
  AES-128 (V4/AESV2) and AES-256 (V5, R5/R6/AESV3), with user or owner
  passwords. Built on OTP's `:crypto`.
  """

  import Bitwise

  defstruct [
    :key,
    :string_method,
    :stream_method,
    :encrypt_metadata,
    :revision,
    :permissions,
    :owner?
  ]

  @type t :: %__MODULE__{}

  @padding <<0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA,
             0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE,
             0x64, 0x53, 0x69, 0x7A>>

  @doc """
  Builds the decryptor from the `/Encrypt` dictionary, the first `/ID`
  string and a password (tried as user, then owner password).
  """
  @spec new(map(), binary(), binary()) :: {:ok, t()} | {:error, :bad_password | :unsupported}
  def new(%{"Filter" => "Standard"} = enc, id, password) do
    v = Map.get(enc, "V", 0)
    r = Map.get(enc, "R", 2)

    cond do
      v in [1, 2, 3, 4] and r in [2, 3, 4] -> legacy(enc, id, password, v, r)
      v == 5 and r in [5, 6] -> aes256(enc, password, r)
      true -> {:error, :unsupported}
    end
  end

  def new(_, _, _), do: {:error, :unsupported}

  defp methods(enc, v) do
    if v == 4 or v == 5 do
      cf = Map.get(enc, "CF", %{})
      method_of = fn name -> method(name, cf) end
      {method_of.(Map.get(enc, "StrF", "Identity")), method_of.(Map.get(enc, "StmF", "Identity"))}
    else
      {:rc4, :rc4}
    end
  end

  defp method("Identity", _), do: :none

  defp method(name, cf) do
    case get_in(cf, [name, "CFM"]) do
      "V2" -> :rc4
      "AESV2" -> :aes
      "AESV3" -> :aes
      "None" -> :none
      _ -> :rc4
    end
  end

  # ---------------------------------------------------------------- R2–R4

  defp legacy(enc, id, password, v, r) do
    o = str(enc["O"]) |> pad_to(32)
    u = str(enc["U"]) |> pad_to(32)
    p = Map.get(enc, "P", 0)
    length_bits = if v == 1, do: 40, else: Map.get(enc, "Length", 40)
    n = if r == 2, do: 5, else: div(length_bits, 8)
    encrypt_metadata = Map.get(enc, "EncryptMetadata", true) != false
    {str_m, stm_m} = methods(enc, v)
    password = password |> binary_part(0, min(byte_size(password), 32))

    base = %__MODULE__{
      string_method: str_m,
      stream_method: stm_m,
      encrypt_metadata: encrypt_metadata,
      revision: r,
      permissions: p
    }

    user_key = compute_key(password, o, p, id, n, r, encrypt_metadata)

    cond do
      check_user(user_key, u, id, r) ->
        {:ok, %{base | key: user_key, owner?: false}}

      true ->
        # owner password: recover the user password (algorithm 7)
        user_pw = recover_user_password(password, o, n, r)
        key = compute_key(user_pw, o, p, id, n, r, encrypt_metadata)

        if check_user(key, u, id, r),
          do: {:ok, %{base | key: key, owner?: true}},
          else: {:error, :bad_password}
    end
  end

  defp compute_key(password, o, p, id, n, r, encrypt_metadata) do
    input =
      [
        pad_password(password),
        o,
        <<p::little-signed-32>>,
        id,
        if(r >= 4 and not encrypt_metadata, do: <<0xFF, 0xFF, 0xFF, 0xFF>>, else: <<>>)
      ]

    hash = :crypto.hash(:md5, input)

    hash =
      if r >= 3,
        do: Enum.reduce(1..50, hash, fn _, h -> :crypto.hash(:md5, binary_part(h, 0, n)) end),
        else: hash

    binary_part(hash, 0, n)
  end

  defp check_user(key, u, _id, 2), do: rc4(key, @padding) == u

  defp check_user(key, u, id, _r) do
    h = :crypto.hash(:md5, [@padding, id])
    out = Enum.reduce(0..19, h, fn i, acc -> rc4(xor_key(key, i), acc) end)
    binary_part(out, 0, 16) == binary_part(u, 0, 16)
  end

  defp recover_user_password(owner_pw, o, n, r) do
    hash = :crypto.hash(:md5, pad_password(owner_pw))

    hash =
      if r >= 3, do: Enum.reduce(1..50, hash, fn _, h -> :crypto.hash(:md5, h) end), else: hash

    key = binary_part(hash, 0, n)

    if r == 2 do
      rc4(key, o)
    else
      Enum.reduce(19..0//-1, o, fn i, acc -> rc4(xor_key(key, i), acc) end)
    end
  end

  defp xor_key(key, i), do: for(<<b <- key>>, into: <<>>, do: <<bxor(b, i)>>)

  defp pad_password(pw) do
    pw = binary_part(pw, 0, min(byte_size(pw), 32))
    pw <> binary_part(@padding, 0, 32 - byte_size(pw))
  end

  # ---------------------------------------------------------------- AES-256

  defp aes256(enc, password, r) do
    password = password |> binary_part(0, min(byte_size(password), 127))
    o = str(enc["O"]) |> pad_to(48)
    u = str(enc["U"]) |> pad_to(48)
    oe = str(enc["OE"]) |> pad_to(32)
    ue = str(enc["UE"]) |> pad_to(32)
    {str_m, stm_m} = methods(enc, 5)

    base = %__MODULE__{
      string_method: str_m,
      stream_method: stm_m,
      encrypt_metadata: Map.get(enc, "EncryptMetadata", true) != false,
      revision: r,
      permissions: Map.get(enc, "P", 0)
    }

    <<u_hash::binary-32, u_valid::binary-8, u_key_salt::binary-8, _::binary>> = u
    <<o_hash::binary-32, o_valid::binary-8, o_key_salt::binary-8, _::binary>> = o
    u48 = binary_part(u, 0, 48)

    cond do
      hash_2b(password, o_valid, u48, r) == o_hash ->
        key = aes_no_iv(hash_2b(password, o_key_salt, u48, r), oe)
        {:ok, %{base | key: key, owner?: true}}

      hash_2b(password, u_valid, <<>>, r) == u_hash ->
        key = aes_no_iv(hash_2b(password, u_key_salt, <<>>, r), ue)
        {:ok, %{base | key: key, owner?: false}}

      true ->
        {:error, :bad_password}
    end
  end

  defp aes_no_iv(key, data) do
    :crypto.crypto_one_time(:aes_256_cbc, key, <<0::128>>, data, encrypt: false, padding: :none)
  end

  # algorithm 2.B (R6) or plain SHA-256 (R5)
  defp hash_2b(password, salt, udata, 5), do: :crypto.hash(:sha256, [password, salt, udata])

  defp hash_2b(password, salt, udata, _r) do
    k = :crypto.hash(:sha256, [password, salt, udata])
    round_2b(password, udata, k, 0)
  end

  defp round_2b(password, udata, k, i) do
    k1 = :binary.copy(password <> k <> udata, 64)
    <<aes_key::binary-16, iv::binary-16, _::binary>> = k

    e =
      :crypto.crypto_one_time(:aes_128_cbc, aes_key, iv, k1, encrypt: true, padding: :none)

    <<first16::binary-16, _::binary>> = e
    mod = rem(:binary.decode_unsigned(first16), 3)

    k =
      case mod do
        0 -> :crypto.hash(:sha256, e)
        1 -> :crypto.hash(:sha384, e)
        2 -> :crypto.hash(:sha512, e)
      end

    last = :binary.last(e)

    if i >= 63 and last <= i - 31,
      do: binary_part(k, 0, 32),
      else: round_2b(password, udata, k, i + 1)
  end

  # ---------------------------------------------------------------- decrypting

  @doc "Decrypts a string of object `num`/`gen`."
  def decrypt_string(%__MODULE__{string_method: m} = c, data, num, gen),
    do: decrypt(c, m, data, num, gen)

  @doc "Decrypts a stream of object `num`/`gen`."
  def decrypt_stream(%__MODULE__{stream_method: m} = c, data, num, gen),
    do: decrypt(c, m, data, num, gen)

  defp decrypt(_c, :none, data, _num, _gen), do: data

  defp decrypt(%{revision: r, key: key}, :aes, data, _num, _gen) when r in [5, 6],
    do: aes_cbc(key, data)

  defp decrypt(c, method, data, num, gen) do
    okey = object_key(c.key, num, gen, method)

    case method do
      :rc4 -> rc4(okey, data)
      :aes -> aes_cbc(okey, data)
    end
  end

  defp object_key(key, num, gen, method) do
    salt = if method == :aes, do: "sAlT", else: <<>>
    h = :crypto.hash(:md5, [key, <<num::little-24, gen::little-16>>, salt])
    binary_part(h, 0, min(byte_size(key) + 5, 16))
  end

  defp aes_cbc(_key, data) when byte_size(data) < 32, do: <<>>

  defp aes_cbc(key, <<iv::binary-16, rest::binary>>) do
    usable = byte_size(rest) - rem(byte_size(rest), 16)
    rest = binary_part(rest, 0, usable)
    cipher = if byte_size(key) == 32, do: :aes_256_cbc, else: :aes_128_cbc
    out = :crypto.crypto_one_time(cipher, key, iv, rest, encrypt: false, padding: :none)
    unpad(out)
  rescue
    _ -> <<>>
  end

  defp unpad(<<>>), do: <<>>

  defp unpad(out) do
    pad = :binary.last(out)

    if pad in 1..16 and pad <= byte_size(out),
      do: binary_part(out, 0, byte_size(out) - pad),
      else: out
  end

  defp rc4(key, data), do: :crypto.crypto_one_time(:rc4, key, data, true)

  defp str({:string, s}), do: s
  defp str(_), do: <<>>

  defp pad_to(s, n) when byte_size(s) >= n, do: s
  defp pad_to(s, n), do: s <> :binary.copy(<<0>>, n - byte_size(s))
end
