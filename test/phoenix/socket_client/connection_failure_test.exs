defmodule Phoenix.SocketClient.ConnectionFailureTest do
  use ExUnit.Case, async: false

  @invalid_url "ws://127.0.0.1:9999/nonexistent/socket"

  test "handles connection failure gracefully" do
    name = :"test_failure_#{System.unique_integer([:positive])}"

    registry_name = :"Registry.Channel_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Phoenix.SocketClient.Supervisor.start_link(
        name: name,
        url: @invalid_url,
        serializer: Jason,
        reconnect_interval: 100,
        registry_name: registry_name
      )

    # Should not be connected to invalid URL
    refute Phoenix.SocketClient.connected?(name)

    # Should return error for unconnected socket
    assert {:error, :socket_not_connected} == Phoenix.SocketClient.Channel.join(name, "rooms:any")
  end

  test "handles protocol version selection" do
    assert Phoenix.SocketClient.Message.serializer("1.0.0") == Phoenix.SocketClient.Message.V1
    assert Phoenix.SocketClient.Message.serializer("2.0.0") == Phoenix.SocketClient.Message.V2
    assert Phoenix.SocketClient.Message.serializer("invalid") == Phoenix.SocketClient.Message.V2
  end

  test "handles invalid socket names gracefully" do
    assert nil == Phoenix.SocketClient.get_process_pid(:nonexistent_socket, :socket)
    assert nil == Phoenix.SocketClient.get_state(:nonexistent_socket, :url)
    assert nil == Phoenix.SocketClient.put_state(:nonexistent_socket, :key, "value")
  end
end
