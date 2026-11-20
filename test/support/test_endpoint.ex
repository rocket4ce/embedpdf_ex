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

defmodule EmbedPdf.TestHostLive do
  @moduledoc false
  # A host LiveView embedding the viewer the way an application does.
  use Phoenix.LiveView

  def mount(_params, session, socket),
    do: {:ok, assign(socket, path: session["path"], password: session["password"])}

  def render(assigns) do
    ~H"""
    <EmbedPdf.Live.viewer socket={@socket} id="host-viewer" path={@path} password={@password} />
    """
  end
end
