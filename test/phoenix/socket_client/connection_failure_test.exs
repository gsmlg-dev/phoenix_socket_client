defmodule Phoenix.SocketClient.ConnectionFailureTest do
  use ExUnit.Case, async: false

  test "handles connection failure gracefully" do
    # Test error handling without actually attempting a connection
    # Attempting to join a channel with a non-existent socket should return an error
    assert {:error, :socket_not_started} == Phoenix.SocketClient.Channel.join(nil, "rooms:any")

    # Test with invalid socket name returns :socket_not_connected
    assert {:error, :socket_not_connected} == Phoenix.SocketClient.Channel.join(:nonexistent_socket, "rooms:any")
  end

  test "handles protocol version selection" do
    # V1 protocol has been deprecated and defaults to V2
    assert Phoenix.SocketClient.Message.serializer("1.0.0") == Phoenix.SocketClient.Message.V2
    assert Phoenix.SocketClient.Message.serializer("2.0.0") == Phoenix.SocketClient.Message.V2
    assert Phoenix.SocketClient.Message.serializer("invalid") == Phoenix.SocketClient.Message.V2
  end

  test "handles invalid socket names gracefully" do
    assert nil == Phoenix.SocketClient.get_process_pid(:nonexistent_socket, :socket)
    assert nil == Phoenix.SocketClient.get_state(:nonexistent_socket, :url)
    assert nil == Phoenix.SocketClient.put_state(:nonexistent_socket, :key, "value")
  end
end
