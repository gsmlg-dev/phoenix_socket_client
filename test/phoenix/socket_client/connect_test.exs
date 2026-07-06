defmodule Phoenix.SocketClient.ConnectTest do
  use ExUnit.Case, async: false

  defmodule OpenTrackingTransport do
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
            :stop -> :ok
          after
            5_000 -> :ok
          end
        end)

      {:ok, transport_pid}
    end

    @impl true
    def close(pid) when is_pid(pid) do
      send(pid, :stop)
      :ok
    end
  end

  test "duplicate connect messages do not open duplicate transports" do
    name = :"duplicate_connect_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Phoenix.SocketClient,
       name: name,
       url: "ws://example.invalid/socket/websocket",
       auto_connect: false,
       reconnect: false,
       transport: OpenTrackingTransport,
       transport_opts: [test_pid: self()]}
    )

    assert :ok = Phoenix.SocketClient.connect(name)
    assert :ok = Phoenix.SocketClient.connect(name)

    assert_receive {:transport_opened, transport_pid}
    refute_receive {:transport_opened, _duplicate_transport_pid}, 100

    transport_ref = Process.monitor(transport_pid)
    send(transport_pid, :stop)
    assert_receive {:DOWN, ^transport_ref, :process, ^transport_pid, :normal}
    assert eventually(fn -> not Phoenix.SocketClient.connected?(name) end)
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
