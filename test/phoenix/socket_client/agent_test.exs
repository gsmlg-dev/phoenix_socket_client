defmodule Phoenix.SocketClient.AgentTest do
  use ExUnit.Case, async: false

  alias Phoenix.SocketClient.Agent

  describe "Agent functionality" do
    test "initializes with correct state" do
      {:ok, pid} =
        Agent.start_link(
          url: "ws://localhost:4000/socket/websocket",
          serializer: Jason,
          params: %{"test" => "value"}
        )

      # Test initial state - URL contains both params in any order
      url = Agent.get(pid, :url)
      assert url =~ "ws://localhost:4000/socket/websocket"
      assert url =~ "vsn=2.0.0"
      assert url =~ "test=value"
      assert %{"test" => "value"} == Agent.get(pid, :params)
      assert :disconnected == Agent.get(pid, :status)
      assert Jason == Agent.get(pid, :json_library)
    end

    test "get and put operations work correctly" do
      {:ok, pid} = Agent.start_link([])

      # Test get/put operations
      assert :disconnected == Agent.get(pid, :status)

      Agent.put(pid, :status, :connected)
      assert :connected == Agent.get(pid, :status)

      Agent.put(pid, :custom_key, "custom_value")
      assert "custom_value" == Agent.get(pid, :custom_key)
    end

    test "connected? function works correctly" do
      {:ok, pid} = Agent.start_link([])

      refute Agent.connected?(pid)

      Agent.put(pid, :status, :connected)
      assert Agent.connected?(pid)

      Agent.put(pid, :status, :disconnected)
      refute Agent.connected?(pid)
    end

    test "pop_all_to_send returns empty list initially" do
      {:ok, pid} = Agent.start_link([])

      assert [] == Agent.pop_all_to_send(pid)
    end
  end
end
