defmodule EmbedPdf.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: EmbedPdf.PubSub},
      EmbedPdf.Store
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: EmbedPdf.Supervisor)
  end
end
