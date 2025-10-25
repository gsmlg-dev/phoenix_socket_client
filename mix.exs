defmodule Phoenix.SocketClient.Mixfile do
  use Mix.Project

  @version "0.7.0"

  def project do
    [
      app: :phoenix_socket_client,
      version: @version,
      elixir: "~> 1.17",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      description: description(),
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      docs: [extras: ["README.md"], main: "readme"],
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:websocket_client, "~> 1.3"},
      {:telemetry, "~> 1.0"},
      {:benchee, "~> 1.4", only: :dev},
      {:benchee_html, "~> 1.0", only: :dev},
      {:phoenix, "~> 1.8", only: :test},
      {:phoenix_pubsub, "~> 2.1", only: :test},
      {:bandit, "~> 1.8", only: :test},
      {:ex_doc, "~> 0.38", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Connect to Phoenix Channels from Elixir
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/gsmlg-dev/phoenix_socket_client"}
    ]
  end

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
