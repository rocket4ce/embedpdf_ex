Application.put_env(:embedpdf_ex, EmbedPdf.TestEndpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("embedpdf-test-secret-", 4),
  live_view: [signing_salt: "embedpdf-test"],
  server: false,
  pubsub_server: EmbedPdf.PubSub
)

{:ok, _} = EmbedPdf.TestEndpoint.start_link()

ExUnit.start()

defmodule EmbedPdf.TestHelpers do
  @moduledoc false
  def fixture(name), do: Path.join([__DIR__, "fixtures", name])

  def open!(name, opts \\ []) do
    {:ok, doc} = EmbedPdf.open(File.read!(fixture(name)), opts)
    doc
  end
end
