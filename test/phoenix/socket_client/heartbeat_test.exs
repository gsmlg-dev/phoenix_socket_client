defmodule Phoenix.SocketClient.HeartbeatTest do
  use ExUnit.Case, async: true

  alias Phoenix.SocketClient, as: Client
  alias Phoenix.SocketClient.{Channel, Message, MessageProcessor, Socket}

  for sync_mode <- [true, false] do
    @sync_mode sync_mode

    test "retains heartbeat encoding state with processor sync_mode=#{sync_mode}" do
      root = start_client(sync_mode: @sync_mode, batch_size: 1)
      processor = Client.get_process_pid(root, :message_processor)

      state = %Socket{
        sup_pid: root,
        status: :connected,
        transport_pid: self(),
        message_processor: processor
      }

      assert {:noreply, queued} = Socket.handle_info(:heartbeat, state)
      on_exit(fn -> Process.cancel_timer(queued.heartbeat_timer) end)

      assert [{encoding_ref, %Message{topic: "phoenix", event: "heartbeat", payload: %{}}}] =
               queued.to_send_r

      assert queued.to_send_count == 1
      assert is_integer(Process.read_timer(queued.heartbeat_timer))
      assert_receive {:encode_result, ^encoding_ref, {:ok, encoded}}

      assert {:noreply, drained} =
               Socket.handle_info({:encode_result, encoding_ref, {:ok, encoded}}, queued)

      assert_receive {:send, ^encoded}
      assert [nil, heartbeat_ref, "phoenix", "heartbeat", %{}] = JSON.decode!(encoded)
      assert is_binary(heartbeat_ref)
      assert drained.to_send_r == []
      assert drained.to_send_count == 0
      assert drained.heartbeat_timer == queued.heartbeat_timer
      assert %{encode_queue_size: 0, pending_replies: 0} = MessageProcessor.stats(processor)
    end
  end

  test "sends heartbeat directly without a message processor" do
    root = start_client([])
    state = %Socket{sup_pid: root, status: :connected, transport_pid: self()}

    assert {:noreply, next} = Socket.handle_info(:heartbeat, state)
    on_exit(fn -> Process.cancel_timer(next.heartbeat_timer) end)

    assert_receive {:send, encoded}
    assert [nil, heartbeat_ref, "phoenix", "heartbeat", %{}] = JSON.decode!(encoded)
    assert is_binary(heartbeat_ref)
    assert next.to_send_r == []
    assert next.to_send_count == 0
    assert is_integer(Process.read_timer(next.heartbeat_timer))
  end

  test "default processor keeps a joined connection alive across server idle windows" do
    port = Application.fetch_env!(:phoenix_socket_client_test, :port)

    root =
      start_client(
        url: "ws://127.0.0.1:#{port}/ws/heartbeat/websocket",
        heartbeat_interval: 50
      )

    assert :ok = Client.connect(root)
    assert eventually(fn -> Client.connected?(root) end)
    assert %{attempt_ref: attempt_ref, status: :connected} = Client.connection_info(root)
    assert {:ok, %{}, channel} = Channel.join(root, "rooms:reply")

    # The endpoint closes a connection after 500ms without client frames.
    # Heartbeats must keep this same connection alive for over three idle windows.
    Process.sleep(1_600)

    assert %{attempt_ref: ^attempt_ref, status: :connected} = Client.connection_info(root)
    assert {:ok, %{"ping" => "pong"}} = Channel.push(channel, "ping", %{})

    socket = Client.get_process_pid(root, :socket)

    assert %{heartbeat_timer: timer} = GenServer.call(socket, :get_state)

    assert is_reference(timer)
  end

  defp start_client(opts) do
    start_supervised!(
      {Client,
       Keyword.merge(
         [
           name: :"heartbeat_#{System.unique_integer([:positive])}",
           url: "ws://example.invalid/socket",
           auto_connect: false,
           reconnect: false,
           heartbeat_interval: 30_000
         ],
         opts
       )}
    )
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
end
