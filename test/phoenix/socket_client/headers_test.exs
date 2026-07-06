defmodule Phoenix.SocketClient.HeadersTest do
  use ExUnit.Case, async: false

  alias Phoenix.SocketClient.Channel

  test "configured websocket headers are sent during the handshake" do
    name = :"headers_#{System.unique_integer([:positive])}"
    port = Application.get_env(:phoenix_socket_client_test, :port)

    {:ok, _pid} =
      Phoenix.SocketClient.start_link(
        name: name,
        url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
        headers: [{"x-backplane-host-token", "secret-token"}]
      )

    wait_for_socket(name)

    assert {:ok, headers, _channel} = Channel.join(name, "rooms:headers")
    assert headers["x-backplane-host-token"] == "secret-token"
  end

  defp wait_for_socket(socket_name, retries \\ 50)

  defp wait_for_socket(_socket_name, 0) do
    raise "Socket did not connect after waiting"
  end

  defp wait_for_socket(socket_name, retries) do
    if Phoenix.SocketClient.connected?(socket_name) do
      :ok
    else
      Process.sleep(100)
      wait_for_socket(socket_name, retries - 1)
    end
  end
end
