defmodule Phoenix.SocketClient.DisconnectTest do
  use ExUnit.Case, async: false

  defmodule CloseTrackingTransport do
    @behaviour Phoenix.SocketClient.Transport

    @impl true
    def open(_url, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      sender = Keyword.fetch!(opts, :sender)

      transport_pid =
        spawn(fn ->
          send(test_pid, {:transport_opened, self()})
          send(sender, {:connected, self()})

          receive do
            :close -> send(test_pid, {:transport_closed, self()})
          after
            5_000 -> :ok
          end
        end)

      {:ok, transport_pid}
    end

    @impl true
    def close(pid) when is_pid(pid) do
      send(pid, :close)
      :ok
    end
  end

  test "disconnect closes the active transport process" do
    name = :"disconnect_transport_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Phoenix.SocketClient,
       name: name,
       url: "ws://example.invalid/socket/websocket",
       auto_connect: false,
       reconnect: false,
       transport: CloseTrackingTransport,
       transport_opts: [test_pid: self()]}
    )

    assert :ok = Phoenix.SocketClient.connect(name)
    assert_receive {:transport_opened, transport_pid}
    transport_ref = Process.monitor(transport_pid)

    assert eventually(fn -> Phoenix.SocketClient.connected?(name) end)

    assert :ok = Phoenix.SocketClient.disconnect(name)
    assert_receive {:transport_closed, ^transport_pid}
    assert_receive {:DOWN, ^transport_ref, :process, ^transport_pid, :normal}
    refute Phoenix.SocketClient.connected?(name)

    socket_pid = Phoenix.SocketClient.get_process_pid(name, :socket)
    socket_state = GenServer.call(socket_pid, :get_state)

    assert socket_state.status == :disconnected
    assert socket_state.transport_pid == nil
    assert socket_state.transport_ref == nil
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
