defmodule PhoenixSocketClient.SocketTest do
  use ExUnit.Case, async: false

  alias PhoenixSocketClient.Socket

  @port 5807

  @socket_config [
    url: "ws://127.0.0.1:#{@port}/ws/admin/websocket",
    serializer: Jason,
    reconnect_interval: 10
  ]

  setup_all do
    Application.ensure_all_started(:bandit)
    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:jason)
    :ok
  end

  setup do
    start_supervised({Registry, keys: :unique, name: Registry.Connection})
    :ok
  end

  describe "socket connection testing" do
    test "socket can connect to server" do
      name = :"socket_connect_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

      wait_for_socket(name)
      assert Socket.connected?(name)
    end

    test "socket auto-connects by default" do
      name = :"socket_auto_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

      # Default auto_connect is true, should connect automatically
      wait_for_socket(name)
      assert Socket.connected?(name)
    end

    @tag timeout: 10_000
    test "socket does not auto-connect when auto_connect: false" do
      name = :"socket_no_auto_#{System.unique_integer([:positive])}"

      config =
        @socket_config
        |> Keyword.put(:id, name)
        |> Keyword.put(:auto_connect, false)

      {:ok, _pid} = PhoenixSocketClient.start_link(config)

      # Should not connect automatically - give it a moment to ensure
      Process.sleep(500)
      refute Socket.connected?(name)
    end

    test "socket connection status reflects connection state" do
      name = :"socket_status_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

      # Initially disconnected/connecting
      refute Socket.connected?(name)

      # Wait for connection
      wait_for_socket(name)
      assert Socket.connected?(name)
    end

    test "socket handles connection failure gracefully" do
      name = :"socket_fail_#{System.unique_integer([:positive])}"

      config = [
        url: "ws://127.0.0.1:9999/ws/admin/websocket",
        serializer: Jason,
        id: name,
        reconnect_interval: 100
      ]

      {:ok, _pid} = PhoenixSocketClient.start_link(config)

      # Should not be connected to invalid URL
      refute Socket.connected?(name)
    end

    test "socket with custom URL parameters" do
      name = :"socket_params_#{System.unique_integer([:positive])}"

      config =
        @socket_config
        |> Keyword.put(:id, name)
        |> Keyword.put(:params, %{"custom" => "param"})

      {:ok, _pid} = PhoenixSocketClient.start_link(config)
      wait_for_socket(name)
      assert Socket.connected?(name)
    end

    test "socket with custom headers" do
      name = :"socket_headers_#{System.unique_integer([:positive])}"

      config =
        @socket_config
        |> Keyword.put(:id, name)
        |> Keyword.put(:headers, [{"x-custom", "header"}])

      {:ok, _pid} = PhoenixSocketClient.start_link(config)
      wait_for_socket(name)
      assert Socket.connected?(name)
    end
  end

  defp wait_for_socket(socket_name, retries \\ 50) do
    if retries == 0 do
      false
    else
      case Socket.connected?(socket_name) do
        true ->
          true

        false ->
          :timer.sleep(100)
          wait_for_socket(socket_name, retries - 1)
      end
    end
  end
end
