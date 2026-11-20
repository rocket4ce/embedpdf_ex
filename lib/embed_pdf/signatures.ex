defmodule EmbedPdf.Signatures do
  @moduledoc """
  Digital signatures, following EmbedPDF's signature feature: list
  signature fields, check what is signed, fill a field visually without
  sealing it, place a signature mark anywhere as a stamp, and seal a field
  with a digital signature through a pluggable signer.

  Checking and sealing work on PDF *bytes*: a signature covers byte ranges
  of the file, so sealing appends an incremental update (earlier
  signatures stay valid) and checking hashes the exact bytes it is given.

  ## Signers

  `sign/3` takes `signer:` as one of:

    * `{:pem, cert_pem, key_pem}` – a certificate (and optionally its chain,
      signer first) and private key in PEM; RSA and EC keys
    * `{:key, cert_der | [cert_der], private_key_record}` – the same with
      decoded values (`:public_key` key records)
    * `{:remote, cert_der | [cert_der], fun}` – the key lives elsewhere (HSM,
      cloud KMS): `fun.(%{to_be_signed: der, digest: hash, digest_algorithm:
      :sha256})` gets the DER of the CMS signed attributes and its hash and
      returns the raw signature (RSA PKCS#1 v1.5, or ECDSA as DER) or
      `{:ok, signature}`; this module builds the CMS around it
    * a 1-arity function – does all of CMS itself: it gets `%{digest:
      hash_of_byte_ranges, digest_algorithm: :sha256, byte_range: [a, b, c,
      d], sub_filter: "adbe.pkcs7.detached"}` and returns the DER of a
      detached CMS `ContentInfo` (or `{:ok, der}` / `{:error, reason}`)
  """

  alias EmbedPdf.{Annotations, Edit, Forms}
  alias EmbedPdf.PDF.{Document, Incremental, Page, Serializer, Stream}
  alias EmbedPdf.Signatures.{Certificate, CMS, DER, Mark}

  @byte_range_placeholder "[0 0000000000 0000000000 0000000000]"
  @default_size 16_384

  # ---------------------------------------------------------------- fields

  @doc """
  Signature fields: `%{id, name, page, rect, signed?, filled?, widget_id}`
  (`rect` in PDF user space; `filled?` when the widget shows something,
  sealed or not).
  """
  @spec fields(Document.t()) :: [map()]
  def fields(doc) do
    for %{type: :signature} = f <- Forms.fields(doc) do
      w = List.first(f.widgets) || %{}

      %{
        id: f.id,
        name: f.name,
        page: w[:page],
        rect: w[:rect],
        widget_id: w[:id],
        signed?: f.value == :signed,
        filled?: w[:id] != nil and has_appearance?(doc, w.id)
      }
    end
  end

  defp has_appearance?(doc, widget_id) do
    with %{} = w <- Document.resolve(doc, {:ref, widget_id, 0}),
         %{} = ap <- Document.resolve(doc, w["AP"]),
         %Stream{} = n <- Document.resolve(doc, ap["N"]),
         data when is_binary(data) <- Document.stream_data(doc, n) do
      String.trim(data) != ""
    else
      _ -> false
    end
  end

  defp find_field(doc, id_or_name) do
    case Enum.find(fields(doc), &(&1.id == id_or_name or &1.name == id_or_name)) do
      nil ->
        case Forms.get(doc, id_or_name) do
          nil -> {:error, :not_found}
          _other -> {:error, :not_a_signature_field}
        end

      field ->
        {:ok, field}
    end
  end

  # ---------------------------------------------------------------- visual

  @doc """
  Fills a signature field visually, without sealing it: the field's
  widget shows `mark` (see `EmbedPdf.Signatures.Mark`) and the field stays
  unsigned.
  """
  @spec fill_visual(Document.t(), integer() | String.t(), term()) ::
          Document.t() | {:error, term()}
  def fill_visual(doc, field, mark) do
    with {:ok, f} <- find_field(doc, field),
         %{widget_id: wid, rect: {x0, y0, x1, y1}} when is_integer(wid) <- f,
         {doc, ap} <- Mark.appearance(doc, mark, {x1 - x0, y1 - y0}) do
      widget = Document.resolve(doc, {:ref, wid, 0})
      Document.put_object(doc, wid, Map.put(widget, "AP", %{"N" => ap}))
    else
      {:error, _} = err -> err
      _ -> {:error, :no_widget}
    end
  end

  @doc """
  Places a signature mark off any field: a stamp annotation on page
  `page` (zero-based) inside `rect` (user space) whose appearance is the
  mark. Returns `{doc, annotation}`.
  """
  @spec place_mark(
          Document.t(),
          non_neg_integer(),
          {number(), number(), number(), number()},
          term()
        ) ::
          {Document.t(), EmbedPdf.Annotation.t()} | {:error, term()}
  def place_mark(doc, page_index, rect, mark) do
    {x0, y0, x1, y1} = rect = Edit.normalize(rect)

    case {Document.page(doc, page_index), Mark.appearance(doc, mark, {x1 - x0, y1 - y0})} do
      {nil, _} ->
        {:error, :no_page}

      {_page, {:error, _} = err} ->
        err

      {%Page{ref: page_ref} = page, {doc, ap}} ->
        dict = %{
          "Type" => "Annot",
          "Subtype" => "Stamp",
          "Name" => "Signature",
          "Rect" => Edit.rect_array(rect),
          "F" => 4,
          "P" => page_ref,
          "NM" => Edit.text(Edit.unique_name()),
          "M" => Edit.date(),
          "CreationDate" => Edit.date(),
          "AP" => %{"N" => ap},
          "Subj" => Edit.text("Signature")
        }

        {doc, ref} = Document.add_object(doc, dict)
        doc = Edit.put_annots(doc, page, Edit.annots(doc, page) ++ [ref])
        {:ref, id, _} = ref
        {doc, Annotations.get(doc, id)}
    end
  end

  # ---------------------------------------------------------------- sealing

  @doc """
  Seals a signature field with a digital signature, appending an
  incremental update to `pdf_bytes`.

  `target` is a signature field (id or name) or `{:new, page_index, rect}`
  to add a field (an empty rect `{0, 0, 0, 0}` makes an invisible
  signature).

  Options: `signer:` (required, see the module docs), `sub_filter:`
  (`:pkcs7`, the default, for `adbe.pkcs7.detached`, or `:cades` for
  `ETSI.CAdES.detached`), `digest_algorithm:` (`:sha256`), `reason:`,
  `location:`, `contact_info:`, `name:`, `signing_time:` (DateTime),
  `mark:` (the visible appearance; by default the signer's name and the
  date), `field_name:` for new fields, `size:` (bytes reserved for the
  signature, default 16384), `password:` to open the file.
  """
  @spec sign(binary(), term(), keyword()) :: {:ok, binary()} | {:error, term()}
  def sign(pdf_bytes, target, opts) do
    with {:ok, doc} <- EmbedPdf.open(pdf_bytes, password: opts[:password] || ""),
         nil <- doc.crypt,
         {:ok, signer} <- resolve_signer(Keyword.fetch!(opts, :signer)),
         {:ok, original, doc, field} <- prepare_field(doc, target, opts),
         time = opts[:signing_time] || DateTime.utc_now(),
         {:ok, doc} <- put_appearance(doc, field, signer, time, opts),
         {doc, {:ref, sig_num, _} = sig_ref} <- Document.add_object(doc, nil),
         doc = set_field_value(doc, field.id, sig_ref),
         doc = ensure_acroform(doc, field.id),
         sub_filter = sub_filter(opts),
         size = opts[:size] || @default_size,
         body = signature_body(sub_filter, signer, time, size, opts),
         bytes when is_binary(bytes) <-
           Incremental.append_diff(pdf_bytes, original, doc, %{sig_num => {:raw, body}}) do
      seal(bytes, byte_size(pdf_bytes), size, sub_filter, signer, time, opts)
    else
      %EmbedPdf.PDF.Crypt{} -> {:error, :encrypted}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  defp sub_filter(opts) do
    case opts[:sub_filter] do
      :cades -> "ETSI.CAdES.detached"
      "ETSI.CAdES.detached" -> "ETSI.CAdES.detached"
      _ -> "adbe.pkcs7.detached"
    end
  end

  defp resolve_signer({:pem, cert_pem, key_pem}) do
    with [_ | _] = certs <- Certificate.pem_certificates(cert_pem),
         {:ok, key} <- Certificate.pem_private_key(key_pem) do
      resolve_signer({:key, certs, key})
    else
      _ -> {:error, :bad_pem}
    end
  end

  defp resolve_signer({:key, certs, key}) do
    certs = List.wrap(certs)

    case Certificate.read(hd(certs)) do
      {:ok, cert} ->
        {:ok,
         %{
           kind: :key,
           certs: certs,
           cert: cert,
           sign: fn tbs, alg -> :public_key.sign(tbs, alg, key) end
         }}

      :error ->
        {:error, :bad_certificate}
    end
  end

  defp resolve_signer({:remote, certs, fun}) when is_function(fun, 1) do
    certs = List.wrap(certs)

    case Certificate.read(hd(certs)) do
      {:ok, cert} ->
        sign = fn tbs, alg ->
          case fun.(%{to_be_signed: tbs, digest: :crypto.hash(alg, tbs), digest_algorithm: alg}) do
            {:ok, sig} -> sig
            other -> other
          end
        end

        {:ok, %{kind: :key, certs: certs, cert: cert, sign: sign}}

      :error ->
        {:error, :bad_certificate}
    end
  end

  defp resolve_signer(fun) when is_function(fun, 1), do: {:ok, %{kind: :cms, fun: fun, cert: nil}}
  defp resolve_signer(_), do: {:error, :bad_signer}

  defp prepare_field(doc, {:new, page_index, rect}, opts) do
    case Document.page(doc, page_index) do
      nil ->
        {:error, :no_page}

      %Page{ref: page_ref} = page ->
        original = doc
        rect = Edit.normalize(rect)
        name = opts[:field_name] || unique_field_name(doc)

        dict = %{
          "Type" => "Annot",
          "Subtype" => "Widget",
          "FT" => "Sig",
          "T" => Edit.text(name),
          "Rect" => Edit.rect_array(rect),
          "F" => 132,
          "P" => page_ref
        }

        {doc, {:ref, id, _} = ref} = Document.add_object(doc, dict)
        doc = Edit.put_annots(doc, page, Edit.annots(doc, page) ++ [ref])
        {:ok, original, doc, %{id: id, widget_id: id, rect: rect, name: name, new?: true}}
    end
  end

  defp prepare_field(doc, field, _opts) do
    with {:ok, f} <- find_field(doc, field) do
      if f.signed?, do: {:error, :already_signed}, else: {:ok, doc, doc, Map.put(f, :new?, false)}
    end
  end

  defp unique_field_name(doc) do
    taken = doc |> Forms.fields() |> Enum.map(& &1.name) |> MapSet.new()
    n = Enum.find(1..100_000, &(not MapSet.member?(taken, "Signature#{&1}")))
    "Signature#{n}"
  end

  defp put_appearance(doc, %{widget_id: wid, rect: {x0, y0, x1, y1}}, signer, time, opts)
       when is_integer(wid) do
    w = x1 - x0
    h = y1 - y0

    mark =
      opts[:mark] ||
        {:text, opts[:name] || (signer.cert && signer.cert.common_name) || "Signed", date: time}

    result =
      if w <= 0 or h <= 0,
        do: Document.add_object(doc, Edit.form({0, 0, 0, 0}, "")),
        else: Mark.appearance(doc, mark, {w, h})

    case result do
      {:error, _} = err ->
        err

      {doc, ap} ->
        widget = Document.resolve(doc, {:ref, wid, 0})
        {:ok, Document.put_object(doc, wid, Map.put(widget, "AP", %{"N" => ap}))}
    end
  end

  defp put_appearance(doc, _field, _signer, _time, _opts), do: {:ok, doc}

  defp set_field_value(doc, field_id, sig_ref) do
    field = Document.resolve(doc, {:ref, field_id, 0})
    Document.put_object(doc, field_id, Map.put(field, "V", sig_ref))
  end

  defp ensure_acroform(doc, field_id) do
    catalog_ref = doc.trailer["Root"]
    catalog = Document.catalog(doc)
    field_ref = {:ref, field_id, 0}

    {form, form_ref} =
      case catalog["AcroForm"] do
        {:ref, _, _} = r -> {Document.resolve(doc, r) || %{}, r}
        %{} = inline -> {inline, nil}
        _ -> {%{}, nil}
      end

    fields = List.wrap(Document.resolve(doc, form["Fields"]))
    in_tree? = Enum.any?(fields, &(&1 == field_ref)) or has_parent?(doc, field_id)

    {doc, form} =
      case form["Fields"] do
        {:ref, _, _} = arr when not in_tree? ->
          {Document.put_object(doc, arr, fields ++ [field_ref]), form}

        _ when not in_tree? ->
          {doc, Map.put(form, "Fields", fields ++ [field_ref])}

        _ ->
          {doc, form}
      end

    form = Map.put(form, "SigFlags", 3)

    case form_ref do
      {:ref, _, _} ->
        Document.put_object(doc, form_ref, form)

      nil ->
        {doc, ref} = Document.add_object(doc, form)
        Document.put_object(doc, catalog_ref, Map.put(catalog, "AcroForm", ref))
    end
  end

  defp has_parent?(doc, field_id) do
    match?(%{"Parent" => _}, Document.resolve(doc, {:ref, field_id, 0}))
  end

  defp signature_body(sub_filter, signer, time, size, opts) do
    dict =
      %{
        "Type" => "Sig",
        "Filter" => "Adobe.PPKLite",
        "SubFilter" => sub_filter,
        "M" => {:string, EmbedPdf.PDF.TextString.format_date(time)}
      }
      |> put_text("Name", opts[:name] || (signer.cert && signer.cert.common_name))
      |> put_text("Reason", opts[:reason])
      |> put_text("Location", opts[:location])
      |> put_text("ContactInfo", opts[:contact_info])
      |> Map.put("Prop_Build", %{"App" => %{"Name" => "EmbedPdf"}})

    inner = dict |> Serializer.serialize() |> IO.iodata_to_binary()
    inner = binary_part(inner, 2, byte_size(inner) - 4)

    [
      "<<",
      inner,
      "\n/ByteRange ",
      @byte_range_placeholder,
      "\n/Contents <",
      :binary.copy("0", 2 * size),
      ">>>"
    ]
  end

  defp put_text(map, _key, nil), do: map
  defp put_text(map, key, value), do: Map.put(map, key, Edit.text(to_string(value)))

  defp seal(bytes, original_size, size, sub_filter, signer, time, opts) do
    placeholder = "<" <> :binary.copy("0", 2 * size) <> ">"
    scope = {original_size, byte_size(bytes) - original_size}

    with {a, _} <- :binary.match(bytes, placeholder, scope: scope),
         {br_at, br_len} <- :binary.match(bytes, @byte_range_placeholder, scope: scope) do
      b = a + byte_size(placeholder)
      c = byte_size(bytes) - b
      range = "[0 #{a} #{b} #{c}]"
      range = String.pad_trailing(String.trim_trailing(range, "]"), br_len - 1) <> "]"

      bytes =
        IO.iodata_to_binary([
          binary_part(bytes, 0, br_at),
          range,
          binary_part(bytes, br_at + br_len, byte_size(bytes) - br_at - br_len)
        ])

      alg = opts[:digest_algorithm] || :sha256

      digest =
        :crypto.hash_init(alg)
        |> :crypto.hash_update(binary_part(bytes, 0, a))
        |> :crypto.hash_update(binary_part(bytes, b, c))
        |> :crypto.hash_final()

      cms =
        case signer do
          %{kind: :cms, fun: fun} ->
            fun.(%{
              digest: digest,
              digest_algorithm: alg,
              byte_range: [0, a, b, c],
              sub_filter: sub_filter
            })

          %{kind: :key, certs: certs, sign: sign} ->
            CMS.build(
              digest: digest,
              digest_algorithm: alg,
              certificates: certs,
              sign: &sign.(&1, alg),
              cades: sub_filter == "ETSI.CAdES.detached",
              signing_time: time
            )
        end

      case cms do
        {:ok, der} when is_binary(der) -> splice(bytes, a, size, der)
        der when is_binary(der) -> splice(bytes, a, size, der)
        {:error, _} = err -> err
        other -> {:error, {:bad_cms, other}}
      end
    else
      _ -> {:error, :placeholder_not_found}
    end
  end

  defp splice(bytes, a, size, der) do
    hex = Base.encode16(der)

    if byte_size(hex) > 2 * size do
      {:error, :signature_too_large}
    else
      hex = hex <> :binary.copy("0", 2 * size - byte_size(hex))
      start = a + 1

      {:ok,
       IO.iodata_to_binary([
         binary_part(bytes, 0, start),
         hex,
         binary_part(bytes, start + 2 * size, byte_size(bytes) - start - 2 * size)
       ])}
    end
  end

  # ---------------------------------------------------------------- checking

  @doc """
  Checks every signature in the file. Each result:

      %{field, field_id, signer, signed_at, reason, location, sub_filter,
        byte_range, covers_whole_document?, modified_after?, digest_ok?,
        signature_ok?, certificate: %{subject, issuer, not_before, not_after,
        self_signed?}, status: :valid | :invalid | :unknown, errors}

  `status` is `:valid` when the signed bytes are intact and the signature
  matches its certificate; whether the certificate is *trusted* is left
  to you (see `certificate.self_signed?` and the issuer).

  A signature only vouches for the bytes it covers. When more was appended
  after it (`covers_whole_document?: false`, `modified_after?: true`):

    * `changed_after: :signed` and status `:valid` – every later change is
      covered by a later valid signature over the whole file (a second
      approval, for example);
    * `changed_after: :unsigned` and status `:modified` – the file was
      changed after signing and nobody signed that change. The signed
      version is intact, but what a reader sees now may differ from it, so
      this is never reported as plain `:valid`.
  """
  @spec validate(binary(), keyword()) :: [map()]
  def validate(pdf_bytes, opts \\ []) do
    case EmbedPdf.open(pdf_bytes, password: opts[:password] || "") do
      {:ok, doc} ->
        named =
          for f <- Forms.fields(doc), f.type == :signature, f.value == :signed, into: %{} do
            v = Document.resolve(doc, {:ref, f.id, 0})["V"]
            {ref_num(v), {f.name, f.id}}
          end

        doc.objects
        |> Enum.map(fn {num, v} -> {num, direct_range(doc, v)} end)
        |> Enum.filter(fn {_, v} -> signature_dict?(v) end)
        |> Enum.sort_by(fn {_, v} -> range_start(v) end)
        |> Enum.map(fn {num, dict} ->
          {name, id} = Map.get(named, num, {nil, nil})
          check(pdf_bytes, doc, dict, name, id)
        end)
        |> later_changes()

      {:error, reason} ->
        [%{status: :unknown, errors: ["could not open: #{inspect(reason)}"]}]
    end
  end

  defp ref_num({:ref, n, _}), do: n
  defp ref_num(_), do: nil

  # a /ByteRange kept in another object still names a signature to check
  defp direct_range(doc, %{"ByteRange" => {:ref, _, _} = ref, "Contents" => _} = dict)
       when not is_struct(dict) do
    case Document.resolve(doc, ref) do
      list when is_list(list) ->
        %{dict | "ByteRange" => Enum.map(list, &Document.resolve(doc, &1))}

      _ ->
        dict
    end
  end

  defp direct_range(_doc, value), do: value

  # What was appended after a signature is only vouched for when a later
  # valid signature covers the whole file; otherwise the signature is
  # reported as :modified, not :valid.
  defp later_changes(results) do
    signed_to_the_end? = Enum.any?(results, &(&1.status == :valid and &1.covers_whole_document?))

    Enum.map(results, fn
      %{status: :valid, covers_whole_document?: false} = r ->
        if signed_to_the_end?,
          do: %{r | changed_after: :signed},
          else: %{r | status: :modified, changed_after: :unsigned}

      %{covers_whole_document?: false, byte_range: [_ | _]} = r ->
        %{r | changed_after: if(signed_to_the_end?, do: :signed, else: :unsigned)}

      r ->
        r
    end)
  end

  defp signature_dict?(%{"ByteRange" => [_, _, _, _], "Contents" => _} = d),
    do: d["Type"] in [nil, "Sig", "DocTimeStamp"]

  defp signature_dict?(_), do: false

  defp range_start(%{"ByteRange" => [_, l1, _, _]}) when is_integer(l1), do: l1
  defp range_start(_), do: 0

  defp check(bytes, doc, dict, name, id) do
    sub_filter = Document.resolve(doc, dict["SubFilter"])
    size = byte_size(bytes)

    base = %{
      field: name,
      field_id: id,
      sub_filter: sub_filter,
      reason: Edit.untext(Document.resolve(doc, dict["Reason"])),
      location: Edit.untext(Document.resolve(doc, dict["Location"])),
      byte_range: dict["ByteRange"],
      signer: Edit.untext(Document.resolve(doc, dict["Name"])),
      signed_at: EmbedPdf.PDF.TextString.parse_date(Document.resolve(doc, dict["M"])),
      covers_whole_document?: false,
      modified_after?: false,
      changed_after: nil,
      digest_ok?: false,
      signature_ok?: false,
      certificate: nil,
      status: :unknown,
      errors: []
    }

    with [0, l1, o2, l2] when is_integer(l1) and is_integer(o2) and is_integer(l2) <-
           dict["ByteRange"],
         true <- l1 >= 0 and o2 > l1 and l2 >= 0 and o2 + l2 <= size,
         {:ok, der} <- contents(bytes, l1, o2, dict) do
      tail = binary_part(bytes, o2 + l2, size - o2 - l2)
      whole? = String.trim(tail) == ""

      revision_end? =
        whole? or
          binary_part(bytes, 0, o2 + l2) |> String.trim_trailing() |> String.ends_with?("%%EOF")

      data_fun = fn -> binary_part(bytes, 0, l1) <> binary_part(bytes, o2, l2) end

      base = %{base | covers_whole_document?: whole?, modified_after?: not whole?}

      case CMS.parse(der) do
        {:ok, parsed} ->
          data = data_fun.()
          result = verify(parsed, data, sub_filter)
          cert = result.certificate

          errors =
            result.errors ++
              if(revision_end?, do: [], else: ["the signed range does not end a revision"])

          status =
            cond do
              not result.digest_ok? -> :invalid
              cert == nil -> :unknown
              not result.signature_ok? -> :invalid
              not revision_end? -> :invalid
              true -> :valid
            end

          %{
            base
            | digest_ok?: result.digest_ok?,
              signature_ok?: result.signature_ok?,
              signer: (cert && cert.common_name) || base.signer,
              signed_at: result.signing_time || base.signed_at,
              certificate:
                cert &&
                  Map.take(cert, [
                    :subject,
                    :issuer,
                    :common_name,
                    :not_before,
                    :not_after,
                    :self_signed?
                  ]),
              status: status,
              errors: errors
          }

        {:error, reason} ->
          %{base | errors: ["unreadable signature: #{inspect(reason)}"]}
      end
    else
      _ -> %{base | status: :invalid, errors: ["malformed byte range"]}
    end
  end

  # /Contents read from the gap between the two ranges, so it is the exact
  # hex in the file (and unaffected by string decryption)
  defp contents(bytes, l1, o2, dict) do
    gap = binary_part(bytes, l1, o2 - l1) |> String.trim()

    with "<" <> rest <- gap,
         true <- String.ends_with?(rest, ">"),
         hex = rest |> String.trim_trailing(">") |> String.replace(~r/\s+/, ""),
         hex = if(rem(byte_size(hex), 2) == 1, do: hex <> "0", else: hex),
         {:ok, der} <- Base.decode16(hex, case: :mixed) do
      {:ok, der}
    else
      _ ->
        case dict["Contents"] do
          {:string, der} -> {:ok, der}
          _ -> :error
        end
    end
  end

  # document timestamps sign a TSTInfo whose message imprint is the range digest
  defp verify(parsed, data, "ETSI.RFC3161") do
    result = CMS.verify(parsed, parsed.econtent || <<>>)

    imprint_ok? =
      with {:ok, tst} <- DER.decode(parsed.econtent || <<>>),
           [_version, _policy, imprint | _] <- DER.children(tst),
           [alg, hashed] <- DER.children(imprint),
           [oid | _] <- DER.children(alg),
           digest when digest != nil <- CMS.digest_for_oid(DER.oid(oid)) do
        DER.bytes(hashed) == :crypto.hash(digest, data)
      else
        _ -> false
      end

    %{result | digest_ok?: result.digest_ok? and imprint_ok?}
  end

  defp verify(parsed, data, _sub_filter), do: CMS.verify(parsed, data)
end
