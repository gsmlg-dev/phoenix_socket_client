defmodule Phoenix.SocketClientTest do
  use ExUnit.Case, async: false

  alias Phoenix.SocketClient.{Channel, Message}

  @socket_config [
    # Will be set dynamically
    url: nil,
    serializer: Jason,
    reconnect_interval: 10,
    auto_connect: true,
    vsn: "2.0.0"
  ]

  defp get_port do
    Application.get_env(:phoenix_socket_client_test, :port, 5807)
  end

  defp get_socket_config do
    port = get_port()
    registry_name = :"Registry.Channel_#{System.unique_integer([:positive])}"

    @socket_config
    |> Keyword.put(:url, "ws://127.0.0.1:#{port}/ws/admin/websocket")
    |> Keyword.put(:registry_name, registry_name)
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

  test "socket can join a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    assert {:ok, _, _channel} = Channel.join(name, "rooms:admin-lobby")
  end

  test "socket cannot join more than one channel of the same topic" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    assert {:ok, _, _channel} = Channel.join(name, "rooms:admin-lobby")
    assert {:error, _} = Channel.join(name, "rooms:admin-lobby")
  end

  test "socket can join a channel and receive a reply" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    message = %{"foo" => "bar"}
    assert {:ok, ^message, _channel} = Channel.join(name, "rooms:reply", message)
  end

  test "return an error if socket is down" do
    assert {:error, :socket_not_started} = Channel.join(nil, "rooms:any")
  end

  test "socket can join a channel with params" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    user_id = "123"
    assert {:ok, _, _} = Channel.join(name, "rooms:admin-lobby", %{user: user_id})
    assert_receive %Message{event: "user:entered", payload: %{"user" => ^user_id}}
  end

  test "socket can leave a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:ok, _, _} = Channel.join(name, "rooms:admin-lobby")
    :timer.sleep(100)
    channel_manager = Phoenix.SocketClient.get_process_pid(pid, :channel_manager)

    channel =
      Phoenix.SocketClient.ChannelManager.channel_pid(channel_manager, "rooms:admin-lobby")

    assert :ok = Channel.leave(channel)
  end

  test "client can push to a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert {:ok, %{"test" => "test"}} = Channel.push(channel, "new:msg", %{test: :test})
  end

  test "join timeouts" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:error, :timeout} = Channel.join(name, "rooms:join_timeout", %{}, 1)
  end

  test "push timeouts" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert catch_exit(Channel.push(channel, "foo:bar", %{}, 500))
  end

  test "push async" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert :ok = Channel.push_async(channel, "foo:bar", %{})
  end

  describe "Phoenix.SocketClient state management" do
    test "get_process_pid retrieves correct process pids" do
      name = :"test_socket_#{System.unique_integer([:positive])}"
      port = get_port()

      registry_name = :"Registry.Channel_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Phoenix.SocketClient.Supervisor.start_link(
          name: name,
          url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
          serializer: Jason,
          registry_name: registry_name
        )

      # Test retrieving socket_state pid
      assert state_pid = Phoenix.SocketClient.get_process_pid(name, :socket_state)
      assert is_pid(state_pid)
      assert Process.alive?(state_pid)

      # Test retrieving socket pid
      assert socket_pid = Phoenix.SocketClient.get_process_pid(name, :socket)
      assert is_pid(socket_pid)
      assert Process.alive?(socket_pid)

      # Test retrieving channel_manager pid
      assert manager_pid = Phoenix.SocketClient.get_process_pid(name, :channel_manager)
      assert is_pid(manager_pid)
      assert Process.alive?(manager_pid)

      # Test invalid process name returns nil
      assert nil == Phoenix.SocketClient.get_process_pid(name, :invalid_process)
    end

    test "get_state retrieves state values from socket_state" do
      name = :"test_socket_#{System.unique_integer([:positive])}"

      registry_name = :"Registry.Channel_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Phoenix.SocketClient.Supervisor.start_link(
          name: name,
          url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
          serializer: Jason,
          params: %{"test" => "value"},
          registry_name: registry_name
        )

      # Test retrieving URL
      assert url = Phoenix.SocketClient.get_state(name, :url)
      port = get_port()
      assert url =~ "ws://127.0.0.1:#{port}/ws/admin/websocket"

      # Test retrieving status
      assert status = Phoenix.SocketClient.get_state(name, :status)
      assert status in [:disconnected, :connecting, :connected]

      # Test retrieving params
      assert params = Phoenix.SocketClient.get_state(name, :params)
      assert params == %{"test" => "value"}

      # Test retrieving serializer
      assert serializer = Phoenix.SocketClient.get_state(name, :serializer)
      assert serializer == Phoenix.SocketClient.Message.V2

      # Test retrieving non-existent key returns nil
      assert nil == Phoenix.SocketClient.get_state(name, :non_existent_key)
    end

    test "put_state updates state values in socket_state" do
      name = :"test_socket_#{System.unique_integer([:positive])}"
      port = get_port()

      registry_name = :"Registry.Channel_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Phoenix.SocketClient.Supervisor.start_link(
          name: name,
          url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
          serializer: Jason,
          registry_name: registry_name
        )

      # Test updating a custom state value
      assert :ok = Phoenix.SocketClient.put_state(name, :custom_key, "custom_value")
      assert "custom_value" == Phoenix.SocketClient.get_state(name, :custom_key)

      # Test updating existing state value
      _original_status = Phoenix.SocketClient.get_state(name, :status)
      assert :ok = Phoenix.SocketClient.put_state(name, :status, :test_status)
      assert :test_status == Phoenix.SocketClient.get_state(name, :status)

      # Test updating with different value types
      assert :ok = Phoenix.SocketClient.put_state(name, :test_map, %{key: "value"})
      assert %{key: "value"} == Phoenix.SocketClient.get_state(name, :test_map)

      assert :ok = Phoenix.SocketClient.put_state(name, :test_list, [1, 2, 3])
      assert [1, 2, 3] == Phoenix.SocketClient.get_state(name, :test_list)
    end

    test "state operations handle invalid socket names gracefully" do
      # Test with non-existent socket name
      assert nil == Phoenix.SocketClient.get_process_pid(:non_existent_socket, :socket_state)
      assert nil == Phoenix.SocketClient.get_state(:non_existent_socket, :any_key)
      assert nil == Phoenix.SocketClient.put_state(:non_existent_socket, :key, "value")
    end

    test "state isolation between different socket instances" do
      name1 = :"test_socket_1_#{System.unique_integer([:positive])}"
      name2 = :"test_socket_2_#{System.unique_integer([:positive])}"

      registry_name1 = :"Registry.Channel_#{System.unique_integer([:positive])}"

      {:ok, _pid1} =
        Phoenix.SocketClient.Supervisor.start_link(
          name: name1,
          url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
          serializer: Jason,
          registry_name: registry_name1
        )

      registry_name2 = :"Registry.Channel_#{System.unique_integer([:positive])}"

      {:ok, _pid2} =
        Phoenix.SocketClient.Supervisor.start_link(
          name: name2,
          url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
          serializer: Jason,
          registry_name: registry_name2
        )

      # Test state isolation
      assert :ok = Phoenix.SocketClient.put_state(name1, :test_key, "value1")
      assert :ok = Phoenix.SocketClient.put_state(name2, :test_key, "value2")

      assert "value1" == Phoenix.SocketClient.get_state(name1, :test_key)
      assert "value2" == Phoenix.SocketClient.get_state(name2, :test_key)

      # Test different URLs
      assert url1 = Phoenix.SocketClient.get_state(name1, :url)
      assert url2 = Phoenix.SocketClient.get_state(name2, :url)
      assert url1 == url2
    end
  end

  defp wait_for_socket(socket_name, retries \\ 50) do
    if retries == 0 do
      raise "Socket did not connect in time"
    end

    case Phoenix.SocketClient.connected?(socket_name) do
      true ->
        :ok

      false ->
        :timer.sleep(100)
        wait_for_socket(socket_name, retries - 1)
    end
  end

  describe "channel hooks" do
    setup do
      name = :"socket_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Phoenix.SocketClient.Supervisor.start_link(Keyword.put(get_socket_config(), :name, name))

      wait_for_socket(name)
      {:ok, %{socket: name}}
    end

    test "can register a hook and receive a message", %{socket: name} do
      {:ok, _response, channel} = Channel.join(name, "rooms:admin-lobby")

      test_pid = self()

      Channel.on(channel, "new_msg", fn payload ->
        send(test_pid, {:hook_fired, payload})
      end)

      Phoenix.SocketClientTest.Endpoint.broadcast(
        "rooms:admin-lobby",
        "new_msg",
        %{"hello" => "world"}
      )

      assert_receive {:hook_fired, %{"hello" => "world"}}, 1000
    end

    test "can unregister a hook", %{socket: name} do
      {:ok, _response, channel} = Channel.join(name, "rooms:admin-lobby")

      test_pid = self()

      Channel.on(channel, "new_msg", fn payload ->
        send(test_pid, {:hook_fired, payload})
      end)

      Channel.off(channel, "new_msg")

      Phoenix.SocketClientTest.Endpoint.broadcast(
        "rooms:admin-lobby",
        "new_msg",
        %{"hello" => "world"}
      )

      # The hook should not be fired, so the message should be sent to the test process
      assert_receive %Message{event: "new_msg", payload: %{"hello" => "world"}}, 1000
      refute_receive {:hook_fired, _}, 100
    end

    test "messages without hooks are sent to the parent process", %{socket: name} do
      {:ok, _response, _channel} = Channel.join(name, "rooms:admin-lobby")

      Phoenix.SocketClientTest.Endpoint.broadcast(
        "rooms:admin-lobby",
        "another_event",
        %{"foo" => "bar"}
      )

      assert_receive %Message{event: "another_event", payload: %{"foo" => "bar"}}, 1000
    end

    test "can register a module hook and receive a message", %{socket: name} do
      defmodule MyTestHook do
        def handle_in(event, payload) do
          send(:test_process, {:module_hook_fired, event, payload})
        end
      end

      Process.register(self(), :test_process)

      {:ok, _response, channel} = Channel.join(name, "rooms:admin-lobby")

      Channel.on(channel, "new_msg", MyTestHook)

      Phoenix.SocketClientTest.Endpoint.broadcast(
        "rooms:admin-lobby",
        "new_msg",
        %{"hello" => "world"}
      )

      assert_receive {:module_hook_fired, "new_msg", %{"hello" => "world"}}, 1000
    end
  end
end
