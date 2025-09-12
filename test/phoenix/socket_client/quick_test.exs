defmodule Phoenix.SocketClient.QuickTest do
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

  test "basic startup works" do
    name = :"test_basic_#{System.unique_integer([:positive])}"
    IO.inspect(name)
    # Test basic startup without connection
    {:ok, pid} =
      Phoenix.SocketClient.Supervisor.start_link(
        name: name,
        url: "ws://127.0.0.1:#{get_port()}/ws/admin/websocket",
        serializer: Jason,
        auto_connect: false,
        reconnect_interval: 1000
      )

    assert is_pid(pid)
    assert Process.alive?(pid)

    # Test state retrieval
    assert url = Phoenix.SocketClient.get_state(pid, :url)
    assert url =~ "ws://127.0.0.1"

    # Test process pid retrieval
    assert state_pid = Phoenix.SocketClient.get_process_pid(pid, :socket_state)
    assert is_pid(state_pid)

    Process.exit(pid, :normal)
  end
end
