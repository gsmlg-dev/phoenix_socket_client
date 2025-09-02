defmodule PhoenixSocketClient.ClientTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised({Registry, keys: :unique, name: Registry.Connection})
    :ok
  end

  describe "PhoenixSocketClient state management" do
    test "get_process_pid retrieves correct process pids" do
      name = :"test_client_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        PhoenixSocketClient.start_link(
          name: name,
          url: "ws://localhost:4000/socket/websocket",
          serializer: Jason,
          auto_connect: false
        )

      # Test retrieving process pids
      assert state_pid = PhoenixSocketClient.get_process_pid(pid, :socket_state)
      assert is_pid(state_pid)

      assert socket_pid = PhoenixSocketClient.get_process_pid(pid, :socket)
      assert is_pid(socket_pid)

      assert manager_pid = PhoenixSocketClient.get_process_pid(pid, :channel_manager)
      assert is_pid(manager_pid)

      # Test invalid process name
      assert nil == PhoenixSocketClient.get_process_pid(pid, :invalid_process)
    end

    test "get_state and put_state work correctly" do
      name = :"test_state_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        PhoenixSocketClient.start_link(
          name: name,
          url: "ws://localhost:4000/socket/websocket",
          serializer: Jason,
          params: %{"test" => "value"},
          auto_connect: false
        )

      # Test get_state
      assert url = PhoenixSocketClient.get_state(pid, :url)
      assert url =~ "ws://localhost:4000/socket/websocket"
      assert %{"test" => "value"} = PhoenixSocketClient.get_state(pid, :params)
      assert :disconnected = PhoenixSocketClient.get_state(pid, :status)

      # Test put_state
      assert :ok = PhoenixSocketClient.put_state(pid, :custom_key, "test_value")
      assert "test_value" == PhoenixSocketClient.get_state(pid, :custom_key)

      # Test state isolation
      name2 = :"test_state2_#{System.unique_integer([:positive])}"

      {:ok, _pid2} =
        PhoenixSocketClient.start_link(
          name: name2,
          url: "ws://localhost:4000/socket/websocket",
          serializer: Jason,
          auto_connect: false
        )

      PhoenixSocketClient.put_state(name2, :custom_key, "different_value")
      assert "test_value" == PhoenixSocketClient.get_state(pid, :custom_key)
      assert "different_value" == PhoenixSocketClient.get_state(name2, :custom_key)
    end

    test "handles non-existent sockets gracefully" do
      assert nil == PhoenixSocketClient.get_process_pid(:non_existent, :socket_state)
      assert nil == PhoenixSocketClient.get_state(:non_existent, :any_key)
      assert nil == PhoenixSocketClient.put_state(:non_existent, :key, "value")
    end
  end
end
