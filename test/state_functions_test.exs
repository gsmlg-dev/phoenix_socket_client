defmodule PhoenixSocketClient.StateFunctionsTest do
  use ExUnit.Case, async: false

  @port 5807

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

  test "PhoenixSocketClient.get_state retrieves configuration" do
    name = :"test_config_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(
        id: name,
        url: "ws://127.0.0.1:#{@port}/ws/admin/websocket",
        serializer: Jason,
        auto_connect: false,
        params: %{"test" => "value"}
      )

    # Test that we can retrieve the URL
    url = PhoenixSocketClient.get_state(name, :url)
    assert url =~ "ws://127.0.0.1"

    # Test that we can retrieve params
    params = PhoenixSocketClient.get_state(name, :params)
    assert params["test"] == "value"
  end

  test "PhoenixSocketClient.put_state updates state" do
    name = :"test_update_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(
        id: name,
        url: "ws://127.0.0.1:#{@port}/ws/admin/websocket",
        serializer: Jason,
        auto_connect: false
      )

    # Test updating a custom value
    assert :ok = PhoenixSocketClient.put_state(name, :custom, "test")
    assert "test" == PhoenixSocketClient.get_state(name, :custom)
  end

  test "PhoenixSocketClient.get_process_pid works correctly" do
    name = :"test_pid_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(
        id: name,
        url: "ws://127.0.0.1:#{@port}/ws/admin/websocket",
        serializer: Jason,
        auto_connect: false
      )

    # Test getting process pids
    assert state_pid = PhoenixSocketClient.get_process_pid(name, :socket_state)
    assert is_pid(state_pid)

    assert socket_pid = PhoenixSocketClient.get_process_pid(name, :socket)
    assert is_pid(socket_pid)

    assert manager_pid = PhoenixSocketClient.get_process_pid(name, :channel_manager)
    assert is_pid(manager_pid)
  end
end
