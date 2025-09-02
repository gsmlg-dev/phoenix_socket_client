defmodule PhoenixSocketClient.SocketStateTest do
  use ExUnit.Case, async: false

  alias PhoenixSocketClient.SocketState

  describe "SocketState functionality" do
    test "initializes with correct state" do
      {:ok, pid} =
        SocketState.start_link(
          url: "ws://localhost:4000/socket/websocket",
          serializer: Jason,
          params: %{"test" => "value"}
        )

      # Test initial state - URL contains both params in any order
      url = SocketState.get(pid, :url)
      assert url =~ "ws://localhost:4000/socket/websocket"
      assert url =~ "vsn=2.0.0"
      assert url =~ "test=value"
      assert %{"test" => "value"} == SocketState.get(pid, :params)
      assert :disconnected == SocketState.get(pid, :status)
      assert Jason == SocketState.get(pid, :json_library)
    end

    test "get and put operations work correctly" do
      {:ok, pid} = SocketState.start_link([])

      # Test get/put operations
      assert :disconnected == SocketState.get(pid, :status)

      SocketState.put(pid, :status, :connected)
      assert :connected == SocketState.get(pid, :status)

      SocketState.put(pid, :custom_key, "custom_value")
      assert "custom_value" == SocketState.get(pid, :custom_key)
    end

    test "connected? function works correctly" do
      {:ok, pid} = SocketState.start_link([])

      refute SocketState.connected(pid)

      SocketState.put(pid, :status, :connected)
      assert SocketState.connected(pid)

      SocketState.put(pid, :status, :disconnected)
      refute SocketState.connected(pid)
    end

    test "pop_all_to_send returns empty list initially" do
      {:ok, pid} = SocketState.start_link([])

      assert [] == SocketState.pop_all_to_send(pid)
    end
  end
end
