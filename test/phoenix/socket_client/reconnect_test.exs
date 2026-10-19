defmodule Phoenix.SocketClient.ReconnectTest do
  use ExUnit.Case, async: true

  alias Phoenix.SocketClient
  alias Phoenix.SocketClient.Channel

  defmodule CallbackChannel do
    use Phoenix.SocketClient.Channel

    @impl true
    def handle_join_reply(status, payload, state) do
      send(state.caller, {:join_callback, self(), status, payload})
      {:noreply, state}
    end

    @impl true
    def handle_message(event, payload, state) do
      send(state.caller, {:message_callback, self(), event, payload})
      {:noreply, state}
    end
  end

  defmodule ReplyTransport do
    @behaviour Phoenix.SocketClient.Transport

    @impl true
    def open(_url, opts) do
      sender = Keyword.fetch!(opts, :sender)
      test_pid = Keyword.fetch!(opts, :test_pid)

      pid =
        spawn(fn ->
          send(test_pid, {:transport_opened, self()})
          send(sender, {:connected, self()})
          loop(sender, test_pid)
        end)

      {:ok, pid}
    end

    @impl true
    def close(pid) do
      send(pid, :close)
      :ok
    end

    defp loop(sender, test_pid) do
      receive do
        {:send, encoded} ->
          [join_ref, ref, topic, event, payload] = JSON.decode!(encoded)
          send(test_pid, {:transport_message, self(), topic, event, payload})

          reply = [join_ref, ref, topic, "phx_reply", %{"status" => "ok", "response" => payload}]
          send(sender, {:receive, JSON.encode!(reply)})
          loop(sender, test_pid)

        :disconnect ->
          send(sender, {:disconnected, :network_failure, self()})
          loop(sender, test_pid)

        :close ->
          :ok
      end
    end
  end

  for failure <- [:disconnect, :kill] do
    @failure failure
    test "rejoins saved params after transport #{@failure}" do
      name = unique_name()
      sup = start_client(name, transport: ReplyTransport, transport_opts: [test_pid: self()])
      assert_receive {:transport_opened, old_transport}
      assert eventually(fn -> SocketClient.connected?(sup) end)

      params = %{"user" => "original", "nested" => %{"room" => 42}}
      assert {:ok, ^params, old_channel} = Channel.join(sup, "test:reconnect", params)
      assert_receive {:transport_message, ^old_transport, "test:reconnect", "phx_join", ^params}

      old_ref = Process.monitor(old_channel)

      case @failure do
        :disconnect -> send(old_transport, :disconnect)
        :kill -> Process.exit(old_transport, :kill)
      end

      assert_receive {:DOWN, ^old_ref, :process, ^old_channel, _reason}
      assert_receive {:transport_opened, new_transport}
      refute new_transport == old_transport
      assert_receive {:transport_message, ^new_transport, "test:reconnect", "phx_join", ^params}
      assert eventually(fn -> rejoined?(sup, "test:reconnect", old_channel, params) end)

      %{pid: new_channel} = SocketClient.get_state(sup, :joined_channels)["test:reconnect"]
      assert {:ok, %{"usable" => true}} = Channel.push(new_channel, "ping", %{"usable" => true})

      socket = SocketClient.get_process_pid(sup, :socket)
      send(socket, {:disconnected, :late_notification, old_transport})
      assert SocketClient.connected?(sup)
      assert %{transport_pid: ^new_transport} = GenServer.call(socket, :get_state)
    end
  end

  test "leaving an initial channel prevents it from being revived after reconnect" do
    name = unique_name()

    sup =
      start_client(name,
        transport: ReplyTransport,
        transport_opts: [test_pid: self()],
        join_channels: ["auto:leave", "auto:keep"]
      )

    assert_receive {:transport_opened, old_transport}
    assert eventually(fn -> joined?(sup, "auto:leave") && joined?(sup, "auto:keep") end)
    %{pid: leaving_channel} = SocketClient.get_state(sup, :joined_channels)["auto:leave"]
    %{pid: kept_channel} = SocketClient.get_state(sup, :joined_channels)["auto:keep"]

    # An explicit leave also wins if automatic recovery has already been requested.
    SocketClient.put_state(sup, :reconnecting, true)
    assert :ok = Channel.leave(leaving_channel)
    refute Map.has_key?(SocketClient.get_state(sup, :joined_channels), "auto:leave")

    manager = SocketClient.get_process_pid(sup, :channel_manager)

    assert eventually(fn ->
             case DynamicSupervisor.which_children(manager) do
               [{_, ^kept_channel, :worker, _}] -> true
               _ -> false
             end
           end)

    send(old_transport, :disconnect)
    assert_receive {:transport_opened, new_transport}
    assert_receive {:transport_message, ^new_transport, "auto:keep", "phx_join", %{}}
    assert eventually(fn -> rejoined?(sup, "auto:keep", kept_channel, %{}) end)
    refute Map.has_key?(SocketClient.get_state(sup, :joined_channels), "auto:leave")
    refute_receive {:transport_message, ^new_transport, "auto:leave", "phx_join", _}, 100
  end

  test "restored custom channels keep their callbacks and original caller" do
    sup =
      start_client(unique_name(),
        transport: ReplyTransport,
        transport_opts: [test_pid: self()],
        topic_channel_map: %{"test:callbacks" => CallbackChannel}
      )

    assert_receive {:transport_opened, old_transport}
    assert eventually(fn -> SocketClient.connected?(sup) end)
    params = %{"callback" => "original"}
    assert {:ok, ^params, old_channel} = Channel.join(sup, "test:callbacks", params)
    assert_receive {:join_callback, ^old_channel, :ok, ^params}

    send(old_transport, :disconnect)
    assert_receive {:join_callback, new_channel, :ok, ^params}
    refute new_channel == old_channel

    send(new_channel, %SocketClient.Message{event: "restored", payload: params})
    assert_receive {:message_callback, ^new_channel, "restored", ^params}
  end

  for transport <- [
        Phoenix.SocketClient.Transports.Websocket,
        Phoenix.SocketClient.Transports.OptimizedWebsocket
      ] do
    @transport transport
    test "#{inspect(transport)} restores a real channel after transport death" do
      port = Application.fetch_env!(:phoenix_socket_client_test, :port)

      sup =
        start_client(unique_name(),
          url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
          transport: @transport
        )

      assert eventually(fn -> SocketClient.connected?(sup) end)
      params = %{"generation" => "original"}
      assert {:ok, ^params, old_channel} = Channel.join(sup, "rooms:reply", params)

      socket = SocketClient.get_process_pid(sup, :socket)
      %{transport_pid: old_transport} = GenServer.call(socket, :get_state)
      old_ref = Process.monitor(old_channel)
      Process.exit(old_transport, :kill)

      assert_receive {:DOWN, ^old_ref, :process, ^old_channel, _reason}

      assert eventually(fn ->
               %{transport_pid: new_transport} = GenServer.call(socket, :get_state)

               is_pid(new_transport) && new_transport != old_transport &&
                 rejoined?(sup, "rooms:reply", old_channel, params)
             end)

      %{pid: new_channel} = SocketClient.get_state(sup, :joined_channels)["rooms:reply"]
      assert {:ok, %{"ping" => "pong"}} = Channel.push(new_channel, "ping", %{})

      payload = %{"reconnected" => inspect(@transport)}
      assert {:ok, ^payload} = Channel.push(new_channel, "new:msg", payload)
      assert_receive ^payload
    end
  end

  defp start_client(name, opts) do
    sup =
      start_supervised!(
        {SocketClient,
         Keyword.merge(
           [
             name: name,
             url: "ws://example.invalid/socket/websocket",
             auto_connect: false,
             reconnect_interval: 10
           ],
           opts
         )}
      )

    assert :ok = SocketClient.connect(sup)
    sup
  end

  defp joined?(sup, topic),
    do: get_in(SocketClient.get_state(sup, :joined_channels), [topic, :status]) == :joined

  defp rejoined?(sup, topic, old_channel, params) do
    case SocketClient.get_state(sup, :joined_channels)[topic] do
      %{status: :joined, pid: pid, params: ^params} -> pid != old_channel && Process.alive?(pid)
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp unique_name, do: :"reconnect_#{System.unique_integer([:positive])}"
end
