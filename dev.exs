# A demo app: `mix run dev.exs`, then open http://localhost:4000
#
# The only JavaScript on the page is LiveView's own client, loaded the way
# every Phoenix app loads it. The viewer itself adds none.

port = String.to_integer(System.get_env("PORT", "4000"))

Application.put_env(:embedpdf_ex, Demo.Endpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("embedpdf-demo-secret-", 4),
  live_view: [signing_salt: "embedpdf-demo"],
  http: [ip: {127, 0, 0, 1}, port: port],
  server: true,
  check_origin: false,
  debug_errors: true,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: Demo.ErrorHTML], layout: false],
  pubsub_server: EmbedPdf.PubSub
)

defmodule Demo.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule Demo.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>EmbedPdf · pure Elixir PDF viewer</title>
        <style>
          html, body { margin: 0; height: 100%; font-family: system-ui, sans-serif; }
          .demo { display: flex; flex-direction: column; height: 100vh; }
          .demo > nav { display: flex; gap: 6px; align-items: center; padding: 6px 12px; background: #111827; color: #fff; overflow-x: auto; }
          .demo > nav a { color: #cbd5e1; text-decoration: none; padding: 4px 10px; border-radius: 999px; white-space: nowrap; font-size: 13px; }
          .demo > nav a.on { background: #3b6cf6; color: #fff; }
          .demo > nav strong { margin-right: 8px; white-space: nowrap; }
          .demo > main { flex: 1; min-height: 0; }
        </style>
        <script src="/assets/phoenix/phoenix.min.js"></script>
        <script src="/assets/phoenix_live_view/phoenix_live_view.min.js"></script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {params: {_csrf_token: csrfToken}});
          liveSocket.connect();
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end

defmodule Demo.HomeLive do
  use Phoenix.LiveView

  @fixtures Path.expand("test/fixtures", File.cwd!())

  def mount(params, _session, socket) do
    files = @fixtures |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".pdf")) |> Enum.sort()
    file = if params["file"] in files, do: params["file"], else: "welcome.pdf"
    locale = if params["locale"] in ["en", "es"], do: params["locale"], else: "en"
    {:ok, assign(socket, files: files, file: file, locale: locale, events: [])}
  end

  def handle_info({:embed_pdf, _viewer, event}, socket) do
    {:noreply, assign(socket, events: Enum.take([inspect(event) | socket.assigns.events], 5))}
  end

  def render(assigns) do
    ~H"""
    <div class="demo">
      <nav>
        <strong>EmbedPdf</strong>
        <a :for={f <- @files} href={"/?file=#{f}&locale=#{@locale}"} class={f == @file && "on"}>{f}</a>
        <a href={"/?file=#{@file}&locale=#{if @locale == "en", do: "es", else: "en"}"}>{if @locale == "en", do: "ES", else: "EN"}</a>
      </nav>
      <main>
        <EmbedPdf.Live.viewer
          socket={@socket}
          id={"viewer-" <> String.replace(@file, ~r/\W/, "-")}
          path={Path.join(fixtures(), @file)}
          locale={@locale}
          features={%{"redaction" => true, "measurement" => true, "snapshots" => true, "forms.building" => true}}
        />
      </main>
    </div>
    """
  end

  defp fixtures, do: @fixtures
end

defmodule Demo.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import EmbedPdf.Router

  pipeline :browser do
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {Demo.Layouts, :root}
  end

  embed_pdf_routes "/embedpdf"

  scope "/" do
    pipe_through :browser
    live "/", Demo.HomeLive
  end
end

defmodule Demo.Endpoint do
  use Phoenix.Endpoint, otp_app: :embedpdf_ex

  @session [store: :cookie, key: "_embedpdf_demo", signing_salt: "embedpdf-demo"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

  plug Plug.Static, at: "/assets/phoenix", from: {:phoenix, "priv/static"}
  plug Plug.Static, at: "/assets/phoenix_live_view", from: {:phoenix_live_view, "priv/static"}
  plug Plug.Session, @session
  plug Demo.Router
end

{:ok, _} = Supervisor.start_link([Demo.Endpoint], strategy: :one_for_one)
IO.puts("EmbedPdf demo running at http://localhost:#{port}")
unless IEx.started?(), do: Process.sleep(:infinity)
