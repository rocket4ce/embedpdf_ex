defmodule EmbedPdf.Live.SignaturesLiveTest do
  # sets the application-wide signer, so it cannot run concurrently
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import EmbedPdf.TestHelpers

  @endpoint EmbedPdf.TestEndpoint

  defp mount_viewer(file) do
    {:ok, view, html} =
      live_isolated(build_conn(), EmbedPdf.Live.Viewer, session: %{"path" => fixture(file)})

    {view, html}
  end

  defp a(view), do: :sys.get_state(view.pid).socket.assigns

  test "signed documents show a banner and the validation details" do
    {view, html} = mount_viewer("signatures/signed_two_approvals.pdf")
    assert html =~ "epdf-sigbar"
    assert [_, _] = a(view).signatures
    assert Enum.all?(a(view).signatures, &(&1.status == :valid))

    html = render_click(view, "panel", %{"side" => "right", "panel" => "signatures"})
    assert html =~ "Unchanged since signing"
  end

  test "tampered signatures are reported" do
    {view, html} = mount_viewer("signatures/tampered.pdf")
    assert html =~ "have a problem"
    assert Enum.any?(a(view).signatures, &(&1.status == :invalid))
  end

  test "a signature field can be filled in without a signer" do
    Application.delete_env(:embedpdf_ex, :signer)
    {view, _} = mount_viewer("signatures/unsigned_sigfield.pdf")
    html = render_click(view, "panel", %{"side" => "right", "panel" => "signatures"})
    [field] = EmbedPdf.Signatures.fields(a(view).doc)
    assert html =~ field.name
    render_click(view, "sign_field", %{"field" => "#{field.id}"})
    refute render(view) =~ "Sign and seal"

    view
    |> form("##{a(view).viewer_id}-sign", %{"name" => "Ada Lovelace"})
    |> render_submit(%{"how" => "visual"})

    assert [%{filled?: true, signed?: false}] = EmbedPdf.Signatures.fields(a(view).doc)
  end

  test "with a configured signer the field is sealed and validates" do
    %{cert: cert, key: key} =
      :public_key.pkix_test_root_cert(~c"Test Signer", [{:key, {:rsa, 2048, 65537}}])

    pem = {
      :public_key.pem_encode([{:Certificate, cert, :not_encrypted}]),
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    }

    Application.put_env(:embedpdf_ex, :signer, {:pem, elem(pem, 0), elem(pem, 1)})
    on_exit(fn -> Application.delete_env(:embedpdf_ex, :signer) end)

    {view, _} = mount_viewer("signatures/unsigned_sigfield.pdf")
    [field] = EmbedPdf.Signatures.fields(a(view).doc)
    render_click(view, "sign_field", %{"field" => "#{field.id}"})
    assert render(view) =~ "Sign and seal"

    view
    |> form("##{a(view).viewer_id}-sign", %{"name" => "Test Signer", "reason" => "Approval"})
    |> render_submit(%{"how" => "seal"})

    assert [%{status: :valid, reason: "Approval"}] = a(view).signatures
    # the download keeps the signature valid
    bytes = EmbedPdf.Output.bytes(EmbedPdf.Store.get(a(view).doc_id))
    assert [%{status: :valid}] = EmbedPdf.Signatures.validate(bytes)
  end

  test "editing a signed document keeps the signature through an incremental save" do
    {view, _} = mount_viewer("signatures/signed_two_approvals.pdf")
    render_click(view, "mode", %{"mode" => "shapes"})
    render_click(view, "tool", %{"tool" => "square"})
    send(view.pid, {:embed_pdf, {:pointer, 0, 0.1, 0.1, nil}})
    send(view.pid, {:embed_pdf, {:pointer, 0, 0.2, 0.2, nil}})
    render(view)
    bytes = EmbedPdf.Output.bytes(EmbedPdf.Store.get(a(view).doc_id))
    original = File.read!(fixture("signatures/signed_two_approvals.pdf"))
    assert binary_part(bytes, 0, byte_size(original)) == original
    results = EmbedPdf.Signatures.validate(bytes)
    assert Enum.all?(results, &(&1.digest_ok? and &1.signature_ok?))
    assert Enum.all?(results, &(&1.covers_whole_document? == false))
  end
end
