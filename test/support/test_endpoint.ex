defmodule EmbedPdf.TestRouter do
  @moduledoc false
  use Phoenix.Router
  import EmbedPdf.Router

  embed_pdf_routes "/embedpdf"
end

defmodule EmbedPdf.TestEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :embedpdf_ex

  socket "/live", Phoenix.LiveView.Socket
  plug EmbedPdf.TestRouter
end
