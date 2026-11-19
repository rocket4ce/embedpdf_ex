defmodule EmbedPdf.Router do
  @moduledoc """
  Mounts the viewer's HTTP endpoints in a Phoenix router.

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import EmbedPdf.Router

        scope "/" do
          embed_pdf_routes "/embedpdf"
        end
      end

  Place it outside pipelines that require CSRF tokens or a session: the
  endpoints are addressed by unguessable ids and only read data, except
  `pointer` and `probe`, which forward clicks and sizes to the viewer that
  owns the id.
  """

  @doc "Forwards `path` (default `/embedpdf`) to `EmbedPdf.Web.Plug`."
  defmacro embed_pdf_routes(path \\ "/embedpdf", opts \\ []) do
    quote bind_quoted: [path: path, opts: opts] do
      forward path, EmbedPdf.Web.Plug, opts
    end
  end
end
