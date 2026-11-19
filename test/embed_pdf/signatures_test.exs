defmodule EmbedPdf.SignaturesTest do
  use ExUnit.Case, async: true

  import EmbedPdf.TestHelpers

  alias EmbedPdf.PDF.{Document, Incremental}
  alias EmbedPdf.Signatures
  alias EmbedPdf.Signatures.{CMS, DER, Mark}

  # throwaway self-signed identities, generated per run (never real keys)
  setup_all do
    %{cert: rsa_cert, key: rsa_key} =
      :public_key.pkix_test_root_cert(~c"Ada Lovelace", [{:key, {:rsa, 2048, 65537}}])

    %{cert: ec_cert, key: ec_key} =
      :public_key.pkix_test_root_cert(~c"Grace Hopper", [{:key, {:namedCurve, :secp256r1}}])

    rsa_pem = {
      :public_key.pem_encode([{:Certificate, rsa_cert, :not_encrypted}]),
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)])
    }

    {:ok, rsa: {rsa_cert, rsa_key}, ec: {ec_cert, ec_key}, rsa_pem: rsa_pem}
  end

  defp sig_fixture(name), do: File.read!(fixture("signatures/" <> name))

  defp out_path(name) do
    dir = Path.join(Mix.Project.build_path(), "pdf_check")
    File.mkdir_p!(dir)
    Path.join(dir, name)
  end

  defp pdfsig(bytes, name) do
    case System.find_executable("pdfsig") do
      nil ->
        :skipped

      exe ->
        path = out_path(name)
        File.write!(path, bytes)
        {out, _} = System.cmd(exe, [path], stderr_to_stdout: true)
        out
    end
  end

  defp poppler_ok!(bytes, name) do
    path = out_path(name)
    File.write!(path, bytes)

    for tool <- ["pdftotext", "pdftoppm"], exe = System.find_executable(tool) do
      args =
        if tool == "pdftotext",
          do: [path, "-"],
          else: ["-r", "10", "-png", "-f", "1", "-l", "1", path, path <> "-img"]

      {_, status} = System.cmd(exe, args, stderr_to_stdout: true)
      assert status == 0, "#{tool} failed on #{name}"
    end
  end

  describe "DER" do
    test "round-trips the building blocks" do
      der =
        DER.sequence([
          DER.oid_der({1, 2, 840, 113_549, 1, 7, 2}),
          DER.integer_der(300),
          DER.octet_string("hi")
        ])

      {:ok, seq} = DER.decode(der <> <<0, 0>>)
      [oid, int, os] = DER.children(seq)
      assert DER.oid(oid) == {1, 2, 840, 113_549, 1, 7, 2}
      assert DER.integer(int) == 300
      assert DER.bytes(os) == "hi"
      assert seq.raw == der
    end

    test "SET OF is sorted" do
      assert DER.set([<<4, 1, 2>>, <<4, 1, 1>>]) == <<0x31, 6, 4, 1, 1, 4, 1, 2>>
    end
  end

  describe "CMS" do
    test "builds and verifies RSA and ECDSA, plain and CAdES", ctx do
      data = "the signed byte ranges"

      for {cert, key} <- [ctx.rsa, ctx.ec], cades <- [false, true] do
        {:ok, der} =
          CMS.build(
            digest: :crypto.hash(:sha256, data),
            certificates: [cert],
            sign: &:public_key.sign(&1, :sha256, key),
            cades: cades
          )

        {:ok, parsed} = CMS.parse(der)
        ok = CMS.verify(parsed, data)
        assert ok.digest_ok? and ok.signature_ok?
        refute CMS.verify(parsed, data <> "!").digest_ok?
      end
    end
  end

  describe "incremental updates" do
    test "append keeps the original bytes and chains the trailer" do
      original = File.read!(fixture("welcome.pdf"))
      {:ok, doc} = EmbedPdf.open(original)
      info = Document.info(doc) |> Map.put("Title", {:string, "Changed"})
      {doc2, ref} = Document.add_object(doc, info)
      updated = Incremental.append_diff(original, doc, doc2, %{}, %{"Info" => ref})

      assert binary_part(updated, 0, byte_size(original)) == original
      assert updated =~ "/Prev"
      {:ok, again} = EmbedPdf.open(updated)
      assert EmbedPdf.Metadata.get(again).title == "Changed"
      assert EmbedPdf.page_count(again) == EmbedPdf.page_count(doc)
      poppler_ok!(updated, "incremental-classic.pdf")
    end

    test "files whose newest section is a cross-reference stream get a stream" do
      original = sig_fixture("embedded_attachments.pdf")
      {:ok, doc} = EmbedPdf.open(original)
      {doc2, _} = Document.add_object(doc, %{"Hello" => 1})
      updated = Incremental.append_diff(original, doc, doc2)
      tail = binary_part(updated, byte_size(original), byte_size(updated) - byte_size(original))
      assert tail =~ "/Type /XRef"
      refute tail =~ "\ntrailer"
      assert {:ok, _} = EmbedPdf.open(updated)
      poppler_ok!(updated, "incremental-xrefstm.pdf")
    end

    test "encrypted files are refused" do
      assert {:error, :encrypted} =
               Incremental.append(sig_fixture("aes128_signed.pdf"), %{1 => nil})
    end
  end

  describe "sealing and checking" do
    test "signs a new field with a PEM identity and validates", ctx do
      {cert_pem, key_pem} = ctx.rsa_pem
      original = File.read!(fixture("forms.pdf"))

      {:ok, signed} =
        Signatures.sign(original, {:new, 0, {350, 30, 560, 100}},
          signer: {:pem, cert_pem, key_pem},
          reason: "Approval",
          location: "London"
        )

      assert binary_part(signed, 0, byte_size(original)) == original

      assert [
               %{
                 status: :valid,
                 digest_ok?: true,
                 signature_ok?: true,
                 covers_whole_document?: true,
                 signer: "Ada Lovelace",
                 reason: "Approval",
                 location: "London",
                 sub_filter: "adbe.pkcs7.detached",
                 certificate: %{self_signed?: true}
               }
             ] = Signatures.validate(signed)

      {:ok, doc} = EmbedPdf.open(signed)
      assert [%{name: "Signature1", signed?: true, filled?: true}] = Signatures.fields(doc)

      case pdfsig(signed, "signed-pem.pdf") do
        :skipped -> :ok
        out -> assert out =~ "Signature is Valid"
      end

      poppler_ok!(signed, "signed-pem.pdf")
    end

    test "two signatures in sequence both stay valid (RSA then EC CAdES)", ctx do
      {rsa_cert, rsa_key} = ctx.rsa
      {ec_cert, ec_key} = ctx.ec
      original = File.read!(fixture("ebook.pdf"))

      {:ok, one} =
        Signatures.sign(original, {:new, 0, {40, 40, 240, 110}},
          signer: {:key, rsa_cert, rsa_key}
        )

      {:ok, two} =
        Signatures.sign(one, {:new, 1, {40, 40, 240, 110}},
          signer: {:key, ec_cert, ec_key},
          sub_filter: :cades
        )

      assert [first, second] = Signatures.validate(two)
      assert first.status == :valid and not first.covers_whole_document? and first.modified_after?
      assert second.status == :valid and second.covers_whole_document?
      assert second.sub_filter == "ETSI.CAdES.detached"
      assert second.signer == "Grace Hopper"

      case pdfsig(two, "signed-twice.pdf") do
        :skipped -> :ok
        out -> assert length(Regex.scan(~r/Signature is Valid/, out)) == 2
      end
    end

    test "a changed byte inside the signed range breaks the digest", ctx do
      {cert, key} = ctx.rsa

      {:ok, signed} =
        Signatures.sign(File.read!(fixture("welcome.pdf")), {:new, 0, {0, 0, 0, 0}},
          signer: {:key, cert, key}
        )

      <<pre::binary-size(400), b, post::binary>> = signed
      tampered = pre <> <<Bitwise.bxor(b, 1)>> <> post
      assert [%{status: :invalid, digest_ok?: false}] = Signatures.validate(tampered)
    end

    test "seals an existing field, refuses to sign it twice", ctx do
      {cert, key} = ctx.rsa
      original = sig_fixture("unsigned_sigfield.pdf")
      {:ok, doc} = EmbedPdf.open(original)
      assert [%{name: "sig", signed?: false}] = Signatures.fields(doc)

      {:ok, sealed} =
        Signatures.sign(original, "sig",
          signer: {:key, cert, key},
          mark: {:ink, [[{0.1, 0.5}, {0.9, 0.5}]]}
        )

      assert [%{field: "sig", status: :valid}] = Signatures.validate(sealed)
      assert {:error, :already_signed} = Signatures.sign(sealed, "sig", signer: {:key, cert, key})
      assert {:error, :not_found} = Signatures.sign(original, "nope", signer: {:key, cert, key})
      poppler_ok!(sealed, "sealed-field.pdf")
    end

    test "remote signers and full-CMS signer functions", ctx do
      {cert, key} = ctx.rsa
      original = sig_fixture("unsigned_sigfield.pdf")

      remote = fn %{to_be_signed: tbs, digest_algorithm: alg} ->
        {:ok, :public_key.sign(tbs, alg, key)}
      end

      {:ok, a} = Signatures.sign(original, "sig", signer: {:remote, [cert], remote})
      assert [%{status: :valid}] = Signatures.validate(a)

      full = fn %{digest: digest, digest_algorithm: :sha256, byte_range: [0, _, _, _]} ->
        CMS.build(digest: digest, certificates: [cert], sign: &:public_key.sign(&1, :sha256, key))
      end

      {:ok, b} = Signatures.sign(original, "sig", signer: full)
      assert [%{status: :valid}] = Signatures.validate(b)
    end

    test "encrypted files can be checked but not sealed", ctx do
      {cert, key} = ctx.rsa
      bytes = sig_fixture("aes128_signed.pdf")
      assert [%{status: :valid}] = Signatures.validate(bytes)

      assert {:error, :encrypted} =
               Signatures.sign(bytes, {:new, 0, {0, 0, 0, 0}}, signer: {:key, cert, key})
    end

    test "checks third-party signatures" do
      assert [
               %{field: "first", status: :valid, covers_whole_document?: false},
               %{field: "second", status: :valid, covers_whole_document?: true}
             ] =
               Signatures.validate(sig_fixture("signed_two_approvals.pdf"))

      assert [%{status: :invalid, digest_ok?: false}] =
               Signatures.validate(sig_fixture("tampered.pdf"))
    end

    test "too small a reservation is reported", ctx do
      {cert, key} = ctx.rsa

      assert {:error, :signature_too_large} =
               Signatures.sign(sig_fixture("unsigned_sigfield.pdf"), "sig",
                 signer: {:key, cert, key},
                 size: 64
               )
    end
  end

  describe "visual marks" do
    setup do
      w = 30
      h = 12

      rgba =
        for y <- 0..(h - 1),
            x <- 0..(w - 1),
            into: <<>>,
            do: <<x * 8, 40, 120, if(rem(x + y, 2) == 0, do: 0, else: 255)>>

      {:ok, png: EmbedPdf.Render.PNG.encode(w, h, :rgba, 8, rgba)}
    end

    test "decodes PNGs with transparency", %{png: png} do
      assert {:ok, 30, 12, {"DeviceRGB", rgb}, alpha} = Mark.decode_png(png)
      assert byte_size(rgb) == 30 * 12 * 3
      assert byte_size(alpha) == 30 * 12
    end

    test "fills a field visually without sealing it", %{png: png} do
      {:ok, doc} = EmbedPdf.open(sig_fixture("unsigned_sigfield.pdf"))

      for mark <- [
            {:text, "Grace Hopper", date: true},
            {:image, png},
            {:ink, [[{0.1, 0.2}, {0.9, 0.8}]]}
          ] do
        filled = Signatures.fill_visual(doc, "sig", mark)
        assert [%{filled?: true, signed?: false}] = Signatures.fields(filled)
        {:ok, again} = EmbedPdf.open(EmbedPdf.save(filled))
        assert [%{filled?: true, signed?: false}] = Signatures.fields(again)
      end

      assert {:error, :not_found} = Signatures.fill_visual(doc, "missing", {:text, "x"})
    end

    test "places marks as stamps that render", %{png: png} do
      {:ok, doc} = EmbedPdf.open(File.read!(fixture("forms.pdf")))

      {doc, a} =
        Signatures.place_mark(doc, 0, {60, 60, 260, 120}, {:text, "Ada Lovelace", date: true})

      {doc, b} = Signatures.place_mark(doc, 0, {300, 60, 500, 120}, {:image, png})
      assert a.subtype == :stamp and b.subtype == :stamp
      svg = doc |> EmbedPdf.Render.SVG.render_page(0) |> IO.iodata_to_binary()
      assert svg =~ "data:image/png"
      poppler_ok!(EmbedPdf.save(doc), "marks.pdf")
    end
  end
end
