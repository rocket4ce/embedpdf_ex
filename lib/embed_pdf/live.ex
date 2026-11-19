defmodule EmbedPdf.Live do
  @moduledoc """
  Embeds the viewer in any LiveView or controller-rendered template.

      <EmbedPdf.Live.viewer socket={@socket} id="contract" path={@path} style="height: 80vh" />

  or, with a document you opened yourself:

      {:ok, doc} = EmbedPdf.open(bytes)
      doc_id = EmbedPdf.Store.put(doc, name: "contract.pdf")

      <EmbedPdf.Live.viewer socket={@socket} id="contract" doc_id={@doc_id} />

  The viewer runs as its own nested LiveView process. It sends
  `{:embed_pdf, viewer_id, event}` messages to your LiveView; read the
  edited document back with `EmbedPdf.Store.get(doc_id).doc`.
  """
  use Phoenix.Component

  attr :socket, :any, required: true, doc: "the parent LiveView socket (or conn)"
  attr :id, :string, required: true
  attr :doc_id, :string, default: nil, doc: "a document already in `EmbedPdf.Store`"
  attr :path, :string, default: nil, doc: "a PDF file on the server"
  attr :name, :string, default: nil
  attr :password, :string, default: nil
  attr :base_path, :string, default: "/embedpdf", doc: "where `embed_pdf_routes` is mounted"
  attr :locale, :string, default: "en"
  attr :translations, :map, default: %{}
  attr :theme, :string, default: "system", values: ~w(light dark system)

  attr :features, :map, default: %{}, doc: "feature name => boolean, see `EmbedPdf.Live.Features`"

  attr :read_only, :boolean, default: false

  attr :mode, :string,
    default: nil,
    doc: "initial mode: view, annotate, shapes, insert, form, redact, pages"

  attr :zoom, :any,
    default: nil,
    doc: "\"fit_width\", \"fit_page\", \"automatic\" or a percentage"

  attr :page, :integer, default: nil
  attr :class, :string, default: nil
  attr :style, :string, default: "height: 100%"

  @doc "Renders the viewer."
  def viewer(assigns) do
    session =
      %{
        "doc_id" => assigns.doc_id,
        "path" => assigns.path,
        "name" => assigns.name,
        "password" => assigns.password,
        "base_path" => assigns.base_path,
        "locale" => assigns.locale,
        "translations" => assigns.translations,
        "theme" => assigns.theme,
        "features" => Map.new(assigns.features, fn {k, v} -> {to_string(k), v} end),
        "read_only" => assigns.read_only,
        "mode" => assigns.mode,
        "zoom" => assigns.zoom,
        "page" => assigns.page
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    assigns = assign(assigns, :session, session)

    ~H"""
    {live_render(@socket, EmbedPdf.Live.Viewer,
      id: @id,
      session: @session,
      container: {:div, class: @class, style: @style}
    )}
    """
  end
end
