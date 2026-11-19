defmodule EmbedpdfEx.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :embedpdf_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "A PDF viewer and editor for Phoenix LiveView, written in pure Elixir: " <>
          "no JavaScript to write, no WebAssembly, no native code.",
      package: package(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [
      mod: {EmbedPdf.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:plug, "~> 1.15"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5", only: [:dev, :test]},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"Reference" => "https://github.com/embedpdf/embed-pdf-viewer"}
    ]
  end
end
