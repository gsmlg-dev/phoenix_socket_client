defmodule PhoenixSocketClientTest do
  use ExUnit.Case, async: false

  alias PhoenixSocketClient.{Socket, Channel, Message}

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
    Keyword.put(@socket_config, :url, "ws://127.0.0.1:#{port}/ws/admin/websocket")
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
      PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    assert {:ok, _, _channel} = Channel.join(name, "rooms:admin-lobby")
  end

  test "socket cannot join more than one channel of the same topic" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    assert {:ok, _, _channel} = Channel.join(name, "rooms:admin-lobby")
    assert {:error, _} = Channel.join(name, "rooms:admin-lobby")
  end

  test "socket can join a channel and receive a reply" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

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
      PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    user_id = "123"
    assert {:ok, _, _} = Channel.join(name, "rooms:admin-lobby", %{user: user_id})
    assert_receive %Message{event: "user:entered", payload: %{"user" => ^user_id}}
  end

  test "socket can leave a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:ok, _, _} = Channel.join(name, "rooms:admin-lobby")
    :timer.sleep(100)
    channel_manager = PhoenixSocketClient.get_process_pid(pid, :channel_manager)
    channel = PhoenixSocketClient.ChannelManager.channel_pid(channel_manager, "rooms:admin-lobby")
    assert :ok = Channel.leave(channel)
  end

  test "client can push to a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert {:ok, %{"test" => "test"}} = Channel.push(channel, "new:msg", %{test: :test})
  end

  test "join timeouts" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:error, :timeout} = Channel.join(name, "rooms:join_timeout", %{}, 1)
  end

  test "push timeouts" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert catch_exit(Channel.push(channel, "foo:bar", %{}, 500))
  end

  test "push async" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert :ok = Channel.push_async(channel, "foo:bar", %{})
  end

  describe "PhoenixSocketClient state management" do
    test "get_process_pid retrieves correct process pids" do
      name = :"test_socket_#{System.unique_integer([:positive])}"
      port = get_port()

      {:ok, _pid} =
        PhoenixSocketClient.start_link(
          name: name,
          url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
          serializer: Jason
        )

      # Test retrieving socket_state pid
      assert state_pid = PhoenixSocketClient.get_process_pid(name, :socket_state)
      assert is_pid(state_pid)
      assert Process.alive?(state_pid)

      # Test retrieving socket pid
      assert socket_pid = PhoenixSocketClient.get_process_pid(name, :socket)
      assert is_pid(socket_pid)
      assert Process.alive?(socket_pid)

      # Test retrieving channel_manager pid
      assert manager_pid = PhoenixSocketClient.get_process_pid(name, :channel_manager)
      assert is_pid(manager_pid)
      assert Process.alive?(manager_pid)

      # Test invalid process name returns nil
      assert nil == PhoenixSocketClient.get_process_pid(name, :invalid_process)
    end

    test "get_state retrieves state values from socket_state" do
      name = :"test_socket_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        PhoenixSocketClient.start_link(
          name: name,
          url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
          serializer: Jason,
          params: %{"test" => "value"}
        )

      # Test retrieving URL
      assert url = PhoenixSocketClient.get_state(name, :url)
      port = get_port()
      assert url =~ "ws://127.0.0.1:#{port}/ws/admin/websocket"

      # Test retrieving status
      assert status = PhoenixSocketClient.get_state(name, :status)
      assert status in [:disconnected, :connecting, :connected]

      # Test retrieving params
      assert params = PhoenixSocketClient.get_state(name, :params)
      assert params == %{"test" => "value"}

      # Test retrieving serializer
      assert serializer = PhoenixSocketClient.get_state(name, :serializer)
      assert serializer == PhoenixSocketClient.Message.V2

      # Test retrieving non-existent key returns nil
      assert nil == PhoenixSocketClient.get_state(name, :non_existent_key)
    end

    test "put_state updates state values in socket_state" do
      name = :"test_socket_#{System.unique_integer([:positive])}"
      port = get_port()

      {:ok, _pid} =
        PhoenixSocketClient.start_link(
          name: name,
          url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
          serializer: Jason
        )

      # Test updating a custom state value
      assert :ok = PhoenixSocketClient.put_state(name, :custom_key, "custom_value")
      assert "custom_value" == PhoenixSocketClient.get_state(name, :custom_key)

      # Test updating existing state value
      _original_status = PhoenixSocketClient.get_state(name, :status)
      assert :ok = PhoenixSocketClient.put_state(name, :status, :test_status)
      assert :test_status == PhoenixSocketClient.get_state(name, :status)

      # Test updating with different value types
      assert :ok = PhoenixSocketClient.put_state(name, :test_map, %{key: "value"})
      assert %{key: "value"} == PhoenixSocketClient.get_state(name, :test_map)

      assert :ok = PhoenixSocketClient.put_state(name, :test_list, [1, 2, 3])
      assert [1, 2, 3] == PhoenixSocketClient.get_state(name, :test_list)
    end

    test "state operations handle invalid socket names gracefully" do
      # Test with non-existent socket name
      assert nil == PhoenixSocketClient.get_process_pid(:non_existent_socket, :socket_state)
      assert nil == PhoenixSocketClient.get_state(:non_existent_socket, :any_key)
      assert nil == PhoenixSocketClient.put_state(:non_existent_socket, :key, "value")
    end

    test "state isolation between different socket instances" do
      name1 = :"test_socket_1_#{System.unique_integer([:positive])}"
      name2 = :"test_socket_2_#{System.unique_integer([:positive])}"

      {:ok, _pid1} =
        PhoenixSocketClient.start_link(
          name: name1,
          url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
          serializer: Jason
        )

      {:ok, _pid2} =
        PhoenixSocketClient.start_link(
          name: name2,
          url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
          serializer: Jason
        )

      # Test state isolation
      assert :ok = PhoenixSocketClient.put_state(name1, :test_key, "value1")
      assert :ok = PhoenixSocketClient.put_state(name2, :test_key, "value2")

      assert "value1" == PhoenixSocketClient.get_state(name1, :test_key)
      assert "value2" == PhoenixSocketClient.get_state(name2, :test_key)

      # Test different URLs
      assert url1 = PhoenixSocketClient.get_state(name1, :url)
      assert url2 = PhoenixSocketClient.get_state(name2, :url)
      assert url1 == url2
    end
  end

  defp wait_for_socket(socket_name, retries \\ 50) do
    if retries == 0 do
      raise "Socket did not connect in time"
    end

    case Socket.connected?(socket_name) do
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
        PhoenixSocketClient.start_link(Keyword.put(get_socket_config(), :name, name))

      wait_for_socket(name)
      {:ok, %{socket: name}}
    end

    test "can register a hook and receive a message", %{socket: name} do
      {:ok, _response, channel} = Channel.join(name, "rooms:admin-lobby")

      test_pid = self()

      Channel.on(channel, "new_msg", fn payload ->
        send(test_pid, {:hook_fired, payload})
      end)

      PhoenixSocketClientTest.Endpoint.broadcast(
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

      PhoenixSocketClientTest.Endpoint.broadcast(
        "rooms:admin-lobby",
        "new_msg",
        %{"hello" => "world"}
      )

      # The hook should not be fired, so the message should be sent to the test process
      assert_receive %Message{event: "new_msg", payload: %{"hello" => "world"}}, 1000
      refute_receive {:hook_fired, _}, 100
    end

    test "messages without hooks are sent to the parent process", %{socket: name} do
      {:ok, _response, channel} = Channel.join(name, "rooms:admin-lobby")

      PhoenixSocketClientTest.Endpoint.broadcast(
        "rooms:admin-lobby",
        "another_event",
        %{"foo" => "bar"}
      )

      assert_receive %Message{event: "another_event", payload: %{"foo" => "bar"}}, 1000
    end
  end
end
