defmodule PhoenixSocketClient.Mixfile do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :phoenix_socket_client,
      version: @version,
      elixir: "~> 1.17",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: [extras: ["README.md"], main: "readme"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.2"},
      {:websocket_client, "~> 1.3"},
      {:telemetry, "~> 1.0"},
      {:phoenix, "~> 1.7", only: :test},
      {:plug_cowboy, "~> 2.5", only: :test},
      {:bandit, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.18", only: :dev}
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
end
