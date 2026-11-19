defmodule EmbedPdf.Signatures.CMS do
  @moduledoc """
  CMS `SignedData` (RFC 5652) as PDF signatures use it: detached
  signatures over the document's byte ranges (`adbe.pkcs7.detached`,
  `ETSI.CAdES.detached`) and the older `adbe.pkcs7.sha1`.

  `parse/1` and `verify/2` check a signature; `build/2` makes one.
  """

  alias EmbedPdf.Signatures.{Certificate, DER}

  @signed_data {1, 2, 840, 113_549, 1, 7, 2}
  @data {1, 2, 840, 113_549, 1, 7, 1}
  @attr_content_type {1, 2, 840, 113_549, 1, 9, 3}
  @attr_message_digest {1, 2, 840, 113_549, 1, 9, 4}
  @attr_signing_time {1, 2, 840, 113_549, 1, 9, 5}
  @attr_signing_cert_v2 {1, 2, 840, 113_549, 1, 9, 16, 2, 47}

  @digests %{
    {1, 3, 14, 3, 2, 26} => :sha,
    {2, 16, 840, 1, 101, 3, 4, 2, 4} => :sha224,
    {2, 16, 840, 1, 101, 3, 4, 2, 1} => :sha256,
    {2, 16, 840, 1, 101, 3, 4, 2, 2} => :sha384,
    {2, 16, 840, 1, 101, 3, 4, 2, 3} => :sha512,
    # signature algorithm OIDs some signers put in digestAlgorithm
    {1, 2, 840, 113_549, 1, 1, 5} => :sha,
    {1, 2, 840, 113_549, 1, 1, 11} => :sha256,
    {1, 2, 840, 113_549, 1, 1, 12} => :sha384,
    {1, 2, 840, 113_549, 1, 1, 13} => :sha512,
    {1, 2, 840, 113_549, 1, 1, 14} => :sha224
  }
  @digest_oids %{
    sha: {1, 3, 14, 3, 2, 26},
    sha224: {2, 16, 840, 1, 101, 3, 4, 2, 4},
    sha256: {2, 16, 840, 1, 101, 3, 4, 2, 1},
    sha384: {2, 16, 840, 1, 101, 3, 4, 2, 2},
    sha512: {2, 16, 840, 1, 101, 3, 4, 2, 3}
  }

  @rsa_sigs %{
    {1, 2, 840, 113_549, 1, 1, 1} => nil,
    {1, 2, 840, 113_549, 1, 1, 5} => :sha,
    {1, 2, 840, 113_549, 1, 1, 11} => :sha256,
    {1, 2, 840, 113_549, 1, 1, 12} => :sha384,
    {1, 2, 840, 113_549, 1, 1, 13} => :sha512,
    {1, 2, 840, 113_549, 1, 1, 14} => :sha224
  }
  @rsa_pss {1, 2, 840, 113_549, 1, 1, 10}
  @ecdsa_sigs %{
    {1, 2, 840, 10045, 2, 1} => nil,
    {1, 2, 840, 10045, 4, 1} => :sha,
    {1, 2, 840, 10045, 4, 3, 1} => :sha224,
    {1, 2, 840, 10045, 4, 3, 2} => :sha256,
    {1, 2, 840, 10045, 4, 3, 3} => :sha384,
    {1, 2, 840, 10045, 4, 3, 4} => :sha512
  }
  @ecdsa_oids %{
    sha: {1, 2, 840, 10045, 4, 1},
    sha224: {1, 2, 840, 10045, 4, 3, 1},
    sha256: {1, 2, 840, 10045, 4, 3, 2},
    sha384: {1, 2, 840, 10045, 4, 3, 3},
    sha512: {1, 2, 840, 10045, 4, 3, 4}
  }

  @type parsed :: %{
          certificates: [binary()],
          signer: map(),
          econtent: binary() | nil
        }

  # ---------------------------------------------------------------- parsing

  @doc "Parses a DER `ContentInfo` holding `SignedData` (trailing padding ignored)."
  @spec parse(binary()) :: {:ok, parsed()} | {:error, term()}
  def parse(der) do
    with {:ok, ci} <- DER.decode(der),
         [type, %{class: :context, tag: 0} = wrapper | _] <- DER.children(ci),
         @signed_data <- DER.oid(type),
         [sd | _] <- DER.children(wrapper),
         [_version, _digest_algs, encap | rest] <- DER.children(sd) do
      {certs, rest} =
        case rest do
          [%{class: :context, tag: 0} = c | more] -> {Enum.map(DER.children(c), & &1.raw), more}
          more -> {[], more}
        end

      rest = Enum.reject(rest, &(&1.class == :context))

      econtent =
        case DER.children(encap) do
          [_oid, %{class: :context, tag: 0} = ec | _] ->
            case DER.children(ec) do
              [os | _] -> collect_octets(os)
              _ -> nil
            end

          _ ->
            nil
        end

      with [infos | _] <- rest,
           [info | _] <- DER.children(infos),
           {:ok, signer} <- signer_info(info) do
        {:ok, %{certificates: certs, signer: signer, econtent: econtent}}
      else
        _ -> {:error, :no_signer_info}
      end
    else
      _ -> {:error, :not_signed_data}
    end
  end

  # an OCTET STRING may be constructed (BER-style chunks)
  defp collect_octets(%{constructed?: true} = el),
    do: el |> DER.children() |> Enum.map_join(&collect_octets/1)

  defp collect_octets(el), do: DER.bytes(el)

  defp signer_info(info) do
    case DER.children(info) do
      [_version, sid, digest_alg | rest] ->
        {signed_attrs, rest} =
          case rest do
            [%{class: :context, tag: 0} = sa | more] -> {sa, more}
            more -> {nil, more}
          end

        [sig_alg, signature | _] = rest

        {:ok,
         %{
           sid: sid_of(sid),
           digest: digest_of(digest_alg),
           signed_attrs: signed_attrs,
           attributes: attributes(signed_attrs),
           signature_algorithm: sig_alg,
           signature: DER.bytes(signature)
         }}

      _ ->
        :error
    end
  end

  defp sid_of(%{class: :context, tag: 0} = ski), do: {:ski, DER.bytes(ski)}

  defp sid_of(sid) do
    case DER.children(sid) do
      [issuer, serial] -> {:issuer_serial, issuer.raw, DER.integer(serial)}
      _ -> :unknown
    end
  end

  defp digest_of(alg) do
    case DER.children(alg) do
      [oid | _] -> Map.get(@digests, DER.oid(oid))
      _ -> nil
    end
  end

  defp attributes(nil), do: %{}

  defp attributes(attrs) do
    for attr <- DER.children(attrs), into: %{} do
      [type, values] = DER.children(attr)
      {DER.oid(type), DER.children(values)}
    end
  end

  # ---------------------------------------------------------------- verifying

  @doc """
  Checks a parsed signature against the signed bytes. Returns
  `%{digest_ok?, signature_ok?, certificate, signing_time, digest, errors}`.
  """
  @spec verify(parsed(), binary()) :: map()
  def verify(%{signer: s} = parsed, data) do
    errors = []
    cert = find_certificate(parsed)
    errors = if cert, do: errors, else: ["signer certificate not found" | errors]
    digest = s.digest
    errors = if digest, do: errors, else: ["unsupported digest algorithm" | errors]

    content =
      case parsed.econtent do
        nil -> data
        econtent -> econtent
      end

    econtent_ok? = parsed.econtent == nil or parsed.econtent == :crypto.hash(:sha, data)

    {digest_ok?, message} =
      cond do
        digest == nil ->
          {false, nil}

        s.signed_attrs != nil ->
          md =
            case Map.get(s.attributes, @attr_message_digest) do
              [os | _] -> DER.bytes(os)
              _ -> nil
            end

          <<_tag, rest::binary>> = s.signed_attrs.raw
          {econtent_ok? and md != nil and md == :crypto.hash(digest, content), <<0x31>> <> rest}

        true ->
          {econtent_ok?, content}
      end

    errors =
      if digest_ok?, do: errors, else: ["the document changed after it was signed" | errors]

    signature_ok? =
      cert != nil and digest != nil and message != nil and
        verify_signature(s, message, digest, cert)

    errors =
      if signature_ok? or cert == nil,
        do: errors,
        else: ["the signature does not match its certificate" | errors]

    signing_time =
      case Map.get(s.attributes, @attr_signing_time) do
        [t | _] -> DER.time(t)
        _ -> nil
      end

    %{
      digest_ok?: digest_ok?,
      signature_ok?: signature_ok?,
      certificate: cert,
      signing_time: signing_time,
      digest: digest,
      errors: Enum.reverse(errors)
    }
  end

  defp find_certificate(%{certificates: ders, signer: %{sid: sid}}) do
    certs =
      ders
      |> Enum.map(&Certificate.read/1)
      |> Enum.flat_map(fn
        {:ok, c} -> [c]
        _ -> []
      end)

    Enum.find(certs, fn c ->
      case sid do
        {:issuer_serial, issuer, serial} -> c.serial == serial and c.issuer_der == issuer
        {:ski, ski} -> c.subject_key_id == ski
        _ -> false
      end
    end) ||
      Enum.find(certs, fn c ->
        match?({:issuer_serial, _, serial} when serial == c.serial, sid)
      end) ||
      if(length(certs) == 1, do: hd(certs))
  end

  defp verify_signature(s, message, digest, cert) do
    alg = s.signature_algorithm

    {oid, params} =
      case DER.children(alg) do
        [o | p] -> {DER.oid(o), p}
        _ -> {nil, []}
      end

    cond do
      Map.has_key?(@rsa_sigs, oid) and cert.key_type == :rsa ->
        hash = Map.get(@rsa_sigs, oid) || digest
        safe_verify(message, hash, s.signature, cert.public_key, [])

      oid == @rsa_pss and cert.key_type == :rsa ->
        {hash, salt} = pss_params(params, digest)

        safe_verify(message, hash, s.signature, cert.public_key,
          rsa_padding: :rsa_pkcs1_pss_padding,
          rsa_pss_saltlen: salt,
          rsa_mgf1_md: hash
        )

      Map.has_key?(@ecdsa_sigs, oid) and cert.key_type == :ec ->
        hash = Map.get(@ecdsa_sigs, oid) || digest
        safe_verify(message, hash, s.signature, cert.public_key, [])

      true ->
        false
    end
  end

  defp safe_verify(message, hash, signature, key, opts) do
    :public_key.verify(message, hash, signature, key, opts)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp pss_params([seq | _], default) do
    fields = DER.children(seq)

    hash =
      Enum.find_value(fields, default, fn
        %{class: :context, tag: 0} = h ->
          with [alg | _] <- DER.children(h),
               [oid | _] <- DER.children(alg),
               do: Map.get(@digests, DER.oid(oid))

        _ ->
          nil
      end) || default

    salt =
      Enum.find_value(fields, 20, fn
        %{class: :context, tag: 2} = s -> s |> DER.children() |> hd() |> DER.integer()
        _ -> nil
      end)

    {hash, salt}
  end

  defp pss_params(_, default), do: {default, 32}

  # ---------------------------------------------------------------- building

  @doc """
  Builds a detached `SignedData` for a byte-range digest.

  Options:

    * `:digest` – the digest of the signed byte ranges (required)
    * `:digest_algorithm` – `:sha256` (default), `:sha384`, `:sha512`
    * `:certificates` – DER certificates, signer first (required)
    * `:sign` – `fn to_be_signed -> raw_signature end`, signing the DER of
      the signed attributes (RSA PKCS#1 v1.5 or ECDSA DER)
    * `:key_type` – `:rsa` or `:ec` (default: from the certificate)
    * `:cades` – add `signingCertificateV2` and leave out `signingTime`
      (ETSI.CAdES.detached); default false
    * `:signing_time` – DateTime (default now)
  """
  @spec build(keyword()) :: {:ok, binary()} | {:error, term()}
  def build(opts) do
    digest = Keyword.fetch!(opts, :digest)
    alg = Keyword.get(opts, :digest_algorithm, :sha256)
    [leaf | _] = certs = Keyword.fetch!(opts, :certificates)
    sign = Keyword.fetch!(opts, :sign)
    cades? = Keyword.get(opts, :cades, false)

    with {:ok, cert} <- Certificate.read(leaf) do
      key_type = Keyword.get(opts, :key_type, cert.key_type)

      attrs =
        [
          attribute(@attr_content_type, DER.oid_der(@data)),
          if(cades?,
            do: nil,
            else:
              attribute(
                @attr_signing_time,
                DER.time_der(Keyword.get(opts, :signing_time, DateTime.utc_now()))
              )
          ),
          attribute(@attr_message_digest, DER.octet_string(digest)),
          if(cades?,
            do: attribute(@attr_signing_cert_v2, signing_certificate_v2(leaf)),
            else: nil
          )
        ]
        |> Enum.reject(&is_nil/1)

      signed_attrs = DER.set(attrs)

      case sign.(signed_attrs) do
        signature when is_binary(signature) ->
          <<0x31, rest::binary>> = signed_attrs

          sig_alg =
            case key_type do
              :ec -> DER.algorithm(Map.fetch!(@ecdsa_oids, alg), false)
              _ -> DER.algorithm({1, 2, 840, 113_549, 1, 1, 1})
            end

          signer_info =
            DER.sequence([
              DER.integer_der(1),
              DER.sequence([cert.issuer_der, cert.serial_der]),
              DER.algorithm(Map.fetch!(@digest_oids, alg), false),
              <<0xA0, rest::binary>>,
              sig_alg,
              DER.octet_string(signature)
            ])

          signed_data =
            DER.sequence([
              DER.integer_der(1),
              DER.set([DER.algorithm(Map.fetch!(@digest_oids, alg), false)]),
              DER.sequence([DER.oid_der(@data)]),
              DER.context(0, certs),
              DER.set([signer_info])
            ])

          {:ok, DER.sequence([DER.oid_der(@signed_data), DER.context(0, [signed_data])])}

        {:error, _} = err ->
          err

        other ->
          {:error, {:bad_signature, other}}
      end
    else
      _ -> {:error, :bad_certificate}
    end
  end

  defp attribute(oid, value), do: DER.sequence([DER.oid_der(oid), DER.set([value])])

  # SigningCertificateV2 ::= SEQUENCE { certs SEQUENCE OF ESSCertIDv2 }
  # ESSCertIDv2 ::= SEQUENCE { hashAlgorithm DEFAULT sha256, certHash OCTET STRING }
  defp signing_certificate_v2(cert_der) do
    DER.sequence([
      DER.sequence([DER.sequence([DER.octet_string(:crypto.hash(:sha256, cert_der))])])
    ])
  end

  @doc "The digest algorithm atom for an OID (nil when unknown)."
  def digest_for_oid(oid), do: Map.get(@digests, oid)
end
