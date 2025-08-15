defmodule PhoenixSocketClient.Socket.StateTest do
  use ExUnit.Case, async: true

  alias PhoenixSocketClient.Socket.State

  @opts [id: __MODULE__, url: "ws://localhost:4000/socket/websocket"]

  setup do
    {:ok, pid} = State.start_link(@opts)
    %{state: pid}
  end

  test "start_link/1 starts the agent", %{state: pid} do
    assert Process.alive?(pid)
  end

  test "get/2 returns the value of a key", %{state: pid} do
    assert State.get(pid, :url) == "ws://localhost:4000/socket/websocket?vsn=2.0.0"
  end

  test "put/3 updates the value of a key", %{state: pid} do
    State.put(pid, :status, :connected)
    assert State.get(pid, :status) == :connected
  end

  test "connected/1 returns the connection status", %{state: pid} do
    refute State.connected(pid)
    State.put(pid, :status, :connected)
    assert State.connected(pid)
  end
end
