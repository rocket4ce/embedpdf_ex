defmodule EmbedPdf.Signatures.Certificate do
  @moduledoc """
  What a signature needs from an X.509 certificate: readable names,
  validity, the public key for verification, and the exact issuer and
  serial bytes that identify it in a CMS `SignerInfo`.
  """

  require Record
  alias EmbedPdf.Signatures.DER

  Record.defrecordp(
    :otp_cert,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :pk_alg,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  @rsa {1, 2, 840, 113_549, 1, 1, 1}
  @rsa_pss {1, 2, 840, 113_549, 1, 1, 10}
  @ec {1, 2, 840, 10045, 2, 1}
  @ski {2, 5, 29, 14}

  @name_oids %{
    {2, 5, 4, 3} => "CN",
    {2, 5, 4, 6} => "C",
    {2, 5, 4, 7} => "L",
    {2, 5, 4, 8} => "ST",
    {2, 5, 4, 10} => "O",
    {2, 5, 4, 11} => "OU",
    {1, 2, 840, 113_549, 1, 9, 1} => "emailAddress"
  }

  @type t :: %{
          der: binary(),
          subject: String.t(),
          issuer: String.t(),
          common_name: String.t() | nil,
          not_before: DateTime.t() | nil,
          not_after: DateTime.t() | nil,
          self_signed?: boolean(),
          serial: integer(),
          issuer_der: binary(),
          serial_der: binary(),
          key_type: :rsa | :ec | :unknown,
          public_key: term(),
          subject_key_id: binary() | nil
        }

  @doc "Reads a DER certificate."
  @spec read(binary()) :: {:ok, t()} | :error
  def read(der) do
    cert = :public_key.pkix_decode_cert(der, :otp)
    t = otp_cert(cert, :tbsCertificate)
    {:Validity, nb, na} = tbs(t, :validity)
    info = spki(tbs(t, :subjectPublicKeyInfo))
    alg = pk_alg(info[:algorithm])

    {key_type, public_key} =
      public_key(alg[:algorithm], alg[:parameters], info[:subjectPublicKey])

    {issuer_der, serial_der} = issuer_and_serial(der)

    {:ok,
     %{
       der: der,
       subject: format_name(tbs(t, :subject)),
       issuer: format_name(tbs(t, :issuer)),
       common_name: common_name(tbs(t, :subject)),
       not_before: otp_time(nb),
       not_after: otp_time(na),
       self_signed?: :public_key.pkix_is_self_signed(cert),
       serial: tbs(t, :serialNumber),
       issuer_der: issuer_der,
       serial_der: serial_der,
       key_type: key_type,
       public_key: public_key,
       subject_key_id: subject_key_id(tbs(t, :extensions))
     }}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp public_key(@rsa, _params, key), do: {:rsa, key}
  defp public_key(@rsa_pss, _params, key), do: {:rsa, key}
  defp public_key(@ec, params, point), do: {:ec, {point, params}}
  defp public_key(_, _, key), do: {:unknown, key}

  # raw issuer Name and serial INTEGER, as a SignerInfo's IssuerAndSerialNumber carries them
  defp issuer_and_serial(der) do
    {:ok, cert} = DER.decode(der)
    [tbs | _] = DER.children(cert)

    fields =
      case DER.children(tbs) do
        [%{class: :context, tag: 0} | rest] -> rest
        all -> all
      end

    [serial, _sig_alg, issuer | _] = fields
    {issuer.raw, serial.raw}
  end

  defp subject_key_id(exts) when is_list(exts) do
    Enum.find_value(exts, fn
      {:Extension, @ski, _critical, value} when is_binary(value) -> value
      _ -> nil
    end)
  end

  defp subject_key_id(_), do: nil

  defp otp_time({:utcTime, t}), do: DER.parse_time(to_string(t), :utc)
  defp otp_time({:generalTime, t}), do: DER.parse_time(to_string(t), :generalized)
  defp otp_time(_), do: nil

  @doc "A readable distinguished name (`CN=Ada, O=Example, C=GB`)."
  def format_name({:rdnSequence, rdns}) do
    rdns
    |> List.flatten()
    |> Enum.map(fn {:AttributeTypeAndValue, oid, value} ->
      key = Map.get(@name_oids, oid, oid |> Tuple.to_list() |> Enum.join("."))
      "#{key}=#{name_value(value)}"
    end)
    |> Enum.join(", ")
  end

  def format_name(_), do: ""

  defp common_name({:rdnSequence, rdns}) do
    rdns
    |> List.flatten()
    |> Enum.find_value(fn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, value} -> name_value(value)
      _ -> nil
    end)
  end

  defp common_name(_), do: nil

  defp name_value({_kind, v}) when is_list(v), do: List.to_string(v)
  defp name_value({_kind, v}) when is_binary(v), do: v
  defp name_value(v) when is_list(v), do: List.to_string(v)
  defp name_value(v) when is_binary(v), do: v
  defp name_value(v), do: inspect(v)

  # ---------------------------------------------------------------- PEM

  @doc "The DER certificates in PEM text, in order."
  @spec pem_certificates(binary()) :: [binary()]
  def pem_certificates(pem) do
    for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
  end

  @doc "The first private key in PEM text, as an OTP key record."
  @spec pem_private_key(binary()) :: {:ok, term()} | :error
  def pem_private_key(pem) do
    case Enum.find(:public_key.pem_decode(pem), fn {type, _, _} ->
           type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo]
         end) do
      nil -> :error
      entry -> {:ok, :public_key.pem_entry_decode(entry)}
    end
  rescue
    _ -> :error
  end

  @doc "The kind of a private key record."
  def private_key_type(key) when is_tuple(key) do
    case elem(key, 0) do
      :RSAPrivateKey -> :rsa
      :ECPrivateKey -> :ec
      _ -> :unknown
    end
  end
end
