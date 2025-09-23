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
      deps: deps()
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
      {:phoenix, "~> 1.7", only: :test},
      {:phoenix_pubsub, "~> 2.0", only: :test},
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
