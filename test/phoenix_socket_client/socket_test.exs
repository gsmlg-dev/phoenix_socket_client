defmodule PhoenixSocketClient.SocketTest do
  use ExUnit.Case, async: false

  alias PhoenixSocketClient.Socket

  defp get_port do
    Application.get_env(:phoenix_socket_client_test, :port, 5807)
  end

  defp get_socket_config do
    port = get_port()

    [
      url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
      serializer: Jason,
      reconnect_interval: 10
    ]
  end

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
        PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

      wait_for_socket(name)
      assert Socket.connected?(name)
    end

    test "socket auto-connects by default" do
      name = :"socket_auto_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

      # Default auto_connect is true, should connect automatically
      wait_for_socket(name)
      assert Socket.connected?(name)
    end

    @tag timeout: 10_000
    test "socket does not auto-connect when auto_connect: false" do
      name = :"socket_no_auto_#{System.unique_integer([:positive])}"

      config =
        get_socket_config()
        |> Keyword.put(:name, name)
        |> Keyword.put(:auto_connect, false)

      {:ok, _pid} = PhoenixSocketClient.start_link(config)

      # Should not connect automatically - give it a moment to ensure
      Process.sleep(500)
      refute Socket.connected?(name)
    end

    test "socket connection status reflects connection state" do
      name = :"socket_status_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

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
        name: name,
        reconnect_interval: 100
      ]

      {:ok, _pid} = PhoenixSocketClient.start_link(config)

      # Should not be connected to invalid URL
      refute Socket.connected?(name)
    end

    test "socket with custom URL parameters" do
      name = :"socket_params_#{System.unique_integer([:positive])}"

      config =
        get_socket_config()
        |> Keyword.put(:name, name)
        |> Keyword.put(:params, %{"custom" => "param"})

      {:ok, _pid} = PhoenixSocketClient.start_link(config)
      wait_for_socket(name)
      assert Socket.connected?(name)
    end

    test "socket with custom headers" do
      name = :"socket_headers_#{System.unique_integer([:positive])}"

      config =
        get_socket_config()
        |> Keyword.put(:name, name)
        |> Keyword.put(:headers, [{"x-custom", "header"}])

      {:ok, _pid} = PhoenixSocketClient.start_link(config)
      wait_for_socket(name)
      assert Socket.connected?(name)
    end
  end

  defmodule MyTestChannel do
    use PhoenixSocketClient.Channel

    @impl true
    def init({_sup_pid, _socket_pid, topic, params}) do
      test_pid = Map.get(params, "test_pid")
      send(test_pid, {:channel_started, topic})
      {:ok, %{}}
    end
  end

  test "socket uses custom channel from topic_channel_map" do
    name = :"socket_custom_channel_#{System.unique_integer([:positive])}"

    topic = "custom:topic"

    config =
      get_socket_config()
      |> Keyword.put(:name, name)
      |> Keyword.put(:topic_channel_map, %{topic => MyTestChannel})

    {:ok, sup_pid} = PhoenixSocketClient.start_link(config)

    # The channel needs the socket to be connected to join
    wait_for_socket(name)

    {:ok, _, _channel_pid} =
      PhoenixSocketClient.Channel.join(sup_pid, topic, %{"test_pid" => self()})

    assert_receive {:channel_started, ^topic}, 5000
  end

  defp wait_for_socket(socket_name, retries \\ 300) do
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
