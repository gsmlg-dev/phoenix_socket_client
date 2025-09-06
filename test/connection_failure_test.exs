defmodule PhoenixSocketClient.ConnectionFailureTest do
  use ExUnit.Case, async: false

  alias PhoenixSocketClient.Socket

  @invalid_url "ws://127.0.0.1:9999/nonexistent/socket"

  test "handles connection failure gracefully" do
    name = :"test_failure_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(
        name: name,
        url: @invalid_url,
        serializer: Jason,
        reconnect_interval: 100
      )

    # Should not be connected to invalid URL
    refute Socket.connected?(name)

    # Should return error for unconnected socket
    assert {:error, :socket_not_connected} == PhoenixSocketClient.Channel.join(name, "rooms:any")
  end

  test "handles protocol version selection" do
    assert PhoenixSocketClient.Message.serializer("1.0.0") == PhoenixSocketClient.Message.V1
    assert PhoenixSocketClient.Message.serializer("2.0.0") == PhoenixSocketClient.Message.V2
    assert PhoenixSocketClient.Message.serializer("invalid") == PhoenixSocketClient.Message.V2
  end

  test "handles invalid socket names gracefully" do
    assert nil == PhoenixSocketClient.get_process_pid(:nonexistent_socket, :socket)
    assert nil == PhoenixSocketClient.get_state(:nonexistent_socket, :url)
    assert nil == PhoenixSocketClient.put_state(:nonexistent_socket, :key, "value")
  end
end
