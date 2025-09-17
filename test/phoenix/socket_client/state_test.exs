defmodule Phoenix.SocketClient.StateTest do
  use ExUnit.Case, async: false

  defp get_port do
    Application.get_env(:phoenix_socket_client_test, :port, 5807)
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

  describe "Phoenix.SocketClient state management" do
    test "get_process_pid retrieves correct process pids" do
      name = :"test_socket_#{System.unique_integer([:positive])}"

      registry_name = :"Registry.Channel_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Phoenix.SocketClient.Supervisor.start_link(
          name: name,
          url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
          serializer: Jason,
          auto_connect: false,
          registry_name: registry_name
        )

      # Test retrieving socket_state pid
      assert state_pid = Phoenix.SocketClient.get_process_pid(name, :socket_state)
      assert is_pid(state_pid)
      assert Process.alive?(state_pid)

      # Test retrieving socket pid
      assert socket_pid = Phoenix.SocketClient.get_process_pid(name, :socket)
      assert is_pid(socket_pid)

      # Test retrieving channel_manager pid
      assert manager_pid = Phoenix.SocketClient.get_process_pid(name, :channel_manager)
      assert is_pid(manager_pid)

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
          auto_connect: false,
          registry_name: registry_name
        )

      # Test retrieving URL
      assert url = Phoenix.SocketClient.get_state(name, :url)
      assert url =~ "ws://127.0.0.1:#{get_port()}/ws/admin/websocket"

      # Test retrieving params
      assert params = Phoenix.SocketClient.get_state(name, :params)
      assert params["test"] == "value"

      # Test retrieving non-existent key returns nil
      assert nil == Phoenix.SocketClient.get_state(name, :non_existent_key)
    end

    test "put_state updates state values in socket_state" do
      name = :"test_socket_#{System.unique_integer([:positive])}"

      registry_name = :"Registry.Channel_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Phoenix.SocketClient.Supervisor.start_link(
          name: name,
          url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
          serializer: Jason,
          auto_connect: false,
          registry_name: registry_name
        )

      # Test updating a custom state value
      assert :ok = Phoenix.SocketClient.put_state(name, :custom_key, "custom_value")
      assert "custom_value" == Phoenix.SocketClient.get_state(name, :custom_key)

      # Test updating with different value types
      assert :ok = Phoenix.SocketClient.put_state(name, :test_map, %{key: "value"})
      assert %{key: "value"} == Phoenix.SocketClient.get_state(name, :test_map)
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
          auto_connect: false,
          registry_name: registry_name1
        )

      registry_name2 = :"Registry.Channel_#{System.unique_integer([:positive])}"

      {:ok, _pid2} =
        Phoenix.SocketClient.Supervisor.start_link(
          name: name2,
          url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
          serializer: Jason,
          auto_connect: false,
          registry_name: registry_name2
        )

      # Test state isolation
      assert :ok = Phoenix.SocketClient.put_state(name1, :test_key, "value1")
      assert :ok = Phoenix.SocketClient.put_state(name2, :test_key, "value2")

      assert "value1" == Phoenix.SocketClient.get_state(name1, :test_key)
      assert "value2" == Phoenix.SocketClient.get_state(name2, :test_key)
    end
  end
end
