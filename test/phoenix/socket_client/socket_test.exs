defmodule Phoenix.SocketClient.SocketTest do
  use ExUnit.Case, async: false

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
        Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

      wait_for_socket(name)
      assert Phoenix.SocketClient.connected?(name)
    end

    test "socket auto-connects by default" do
      name = :"socket_auto_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

      # Default auto_connect is true, should connect automatically
      wait_for_socket(name)
      assert Phoenix.SocketClient.connected?(name)
    end

    @tag timeout: 10_000
    test "socket does not auto-connect when auto_connect: false" do
      name = :"socket_no_auto_#{System.unique_integer([:positive])}"

      config =
        get_socket_config()
        |> Keyword.put(:name, name)
        |> Keyword.put(:auto_connect, false)

      {:ok, _pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      # Should not connect automatically - give it a moment to ensure
      Process.sleep(500)
      refute Phoenix.SocketClient.connected?(name)
    end

    test "socket connection status reflects connection state" do
      name = :"socket_status_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

      # Initially disconnected/connecting
      refute Phoenix.SocketClient.connected?(name)

      # Wait for connection
      wait_for_socket(name)
      assert Phoenix.SocketClient.connected?(name)
    end

    test "socket handles connection failure gracefully" do
      name = :"socket_fail_#{System.unique_integer([:positive])}"

      config = [
        url: "ws://127.0.0.1:9999/ws/admin/websocket",
        serializer: Jason,
        name: name,
        reconnect_interval: 100
      ]

      {:ok, _pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      # Should not be connected to invalid URL
      refute Phoenix.SocketClient.connected?(name)
    end

    test "socket with custom URL parameters" do
      name = :"socket_params_#{System.unique_integer([:positive])}"

      config =
        get_socket_config()
        |> Keyword.put(:name, name)
        |> Keyword.put(:params, %{"custom" => "param"})

      {:ok, _pid} = Phoenix.SocketClient.Supervisor.start_link(config)
      wait_for_socket(name)
      assert Phoenix.SocketClient.connected?(name)
    end

    test "socket with custom headers" do
      name = :"socket_headers_#{System.unique_integer([:positive])}"

      config =
        get_socket_config()
        |> Keyword.put(:name, name)
        |> Keyword.put(:headers, [{"x-custom", "header"}])

      {:ok, _pid} = Phoenix.SocketClient.Supervisor.start_link(config)
      wait_for_socket(name)
      assert Phoenix.SocketClient.connected?(name)
    end

    test "socket can be disconnected" do
      name = :"socket_disconnect_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

      wait_for_socket(name)
      assert Phoenix.SocketClient.connected?(name)

      assert :ok = Phoenix.SocketClient.disconnect(name)
      # Give it a moment to disconnect
      Process.sleep(100)
      refute Phoenix.SocketClient.connected?(name)
    end

    test "socket tracks joined channels" do
      name = :"socket_tracks_channels_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      wait_for_socket(name)

      assert Phoenix.SocketClient.get_state(sup_pid, :joined_channels) == %{}

      params = %{"foo" => "bar"}
      {:ok, _, channel_pid} = Phoenix.SocketClient.Channel.join(sup_pid, "topic:test", params)

      # Give it a moment to join
      Process.sleep(100)

      channel_data =
        get_in(Phoenix.SocketClient.get_state(sup_pid, :joined_channels), ["topic:test"])

      assert channel_data.status == :joined
      assert channel_data.params == params
      assert is_pid(channel_data.pid)

      :ok = Phoenix.SocketClient.Channel.leave(channel_pid)

      # Give it a moment to leave
      Process.sleep(100)

      assert Phoenix.SocketClient.get_state(sup_pid, :joined_channels) == %{}
    end

    test "rejoins channels after reconnect" do
      name = :"socket_rejoin_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      wait_for_socket(name)

      params = %{"foo" => "bar"}
      {:ok, _, _channel_pid} = Phoenix.SocketClient.Channel.join(sup_pid, "topic:rejoin", params)

      Process.sleep(100)

      channel_data_before =
        get_in(Phoenix.SocketClient.get_state(sup_pid, :joined_channels), ["topic:rejoin"])

      assert channel_data_before.status == :joined
      assert channel_data_before.params == params
      assert is_pid(channel_data_before.pid)

      socket_pid = Phoenix.SocketClient.get_process_pid(sup_pid, :socket)
      socket_state = GenServer.call(socket_pid, :get_state)
      transport_pid = socket_state.transport_pid

      # Stop the transport to simulate a disconnection
      GenServer.stop(transport_pid)

      # Give it a moment to reconnect and rejoin
      Process.sleep(200)
      wait_for_socket(name)

      channel_data_after =
        get_in(Phoenix.SocketClient.get_state(sup_pid, :joined_channels), ["topic:rejoin"])

      assert channel_data_after.status == :joined
      assert channel_data_after.params == params
      assert is_pid(channel_data_after.pid)
    end

    test "socket auto-joins channels from join_channels option" do
      name = :"socket_auto_join_#{System.unique_integer([:positive])}"
      topics = ["auto:join1", "auto:join2"]

      config =
        get_socket_config()
        |> Keyword.put(:name, name)
        |> Keyword.put(:join_channels, topics)

      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)
      wait_for_socket(name)
      # Give time for channels to join
      Process.sleep(100)

      joined_channels = Phoenix.SocketClient.get_state(sup_pid, :joined_channels)
      assert Map.has_key?(joined_channels, "auto:join1")
      assert Map.has_key?(joined_channels, "auto:join2")
      assert get_in(joined_channels, ["auto:join1", :status]) == :joined
      assert get_in(joined_channels, ["auto:join2", :status]) == :joined
    end
  end

  defmodule MyTestChannel do
    use Phoenix.SocketClient.Channel

    @impl true
    def handle_message("test_event", _payload, state) do
      send(Process.whereis(:test_process), :test_event_received)
      {:noreply, state}
    end

    def handle_message(_event, _payload, state) do
      {:noreply, state}
    end
  end

  test "socket uses custom channel from topic_channel_map" do
    name = :"socket_custom_channel_#{System.unique_integer([:positive])}"
    topic = "custom:topic"
    Process.register(self(), :test_process)

    config =
      get_socket_config()
      |> Keyword.put(:name, name)
      |> Keyword.put(:topic_channel_map, %{topic => MyTestChannel})

    {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)
    wait_for_socket(name)

    {:ok, _, _channel_pid} = Phoenix.SocketClient.Channel.join(sup_pid, topic)

    Phoenix.SocketClientTest.Endpoint.broadcast(topic, "test_event", %{})

    assert_receive :test_event_received, 5000
  end

  defp wait_for_socket(socket_name, retries \\ 300) do
    if retries == 0 do
      false
    else
      case Phoenix.SocketClient.connected?(socket_name) do
        true ->
          true

        false ->
          :timer.sleep(100)
          wait_for_socket(socket_name, retries - 1)
      end
    end
  end
end
