defmodule PhoenixSocketClientE2E.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_socket_client_e2e,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["test/support"]
  defp elixirc_paths(_env), do: []

  defp deps do
    [
      phoenix_socket_client_dep(),
      {:phoenix, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.8"},
      {:jason, "~> 1.2"}
    ]
  end

  defp phoenix_socket_client_dep do
    case System.get_env("PHOENIX_SOCKET_CLIENT_PATH") do
      nil -> {:phoenix_socket_client, phoenix_socket_client_version()}
      path -> {:phoenix_socket_client, path: path}
    end
  end

  defp phoenix_socket_client_version do
    System.get_env("PHOENIX_SOCKET_CLIENT_VERSION", "~> 0.7")
  end
end
