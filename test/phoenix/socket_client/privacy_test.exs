defmodule Phoenix.SocketClient.PrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Phoenix.SocketClient.Channel.{Helpers, State}
  alias Phoenix.SocketClient.{Message, MessageProcessor, Socket, Telemetry}

  @sentinel "SSH_PRIVATE_MATERIAL_SENTINEL"

  defmodule PrivateChannel do
    use Phoenix.SocketClient.Channel

    def init(state), do: {:ok, state}
    @impl true
    def handle_message("crash", payload, _state), do: raise(payload["private_key"])

    def handle_message(event, payload, state) do
      send(state.caller, {:delivered, event, payload})
      {:noreply, state}
    end

    def terminate(_, _), do: :ok
  end

  setup do
    old_config = Application.get_env(:phoenix_socket_client, :telemetry)
    Telemetry.reset_config()

    on_exit(fn ->
      if old_config,
        do: Application.put_env(:phoenix_socket_client, :telemetry, old_config),
        else: Application.delete_env(:phoenix_socket_client, :telemetry)
    end)

    :ok
  end

  test "telemetry dispatch drops private content and transport options before any handler" do
    event = [:phoenix, :socket_client, :connection, :start]
    attach([event])

    Telemetry.emit_event(event, %{duration: 42}, %{
      url: "wss://user:#{@sentinel}@example.test/socket?token=#{@sentinel}##{@sentinel}",
      transport: :websocket,
      transport_opts: [ssl: [keyfile: @sentinel]],
      tcp_opts: [password: @sentinel],
      payload: %{"private_key" => @sentinel},
      response: %{"private_key" => @sentinel},
      unknown: %{nested: @sentinel}
    })

    assert_receive {:telemetry, ^event, %{duration: 42}, metadata}
    assert %{url: "wss://example.test/socket", transport: :websocket} = metadata
    assert map_size(metadata) == 2
    refute inspect(metadata, limit: :infinity) =~ @sentinel
  end

  test "typed metadata rejects private values under operational field names" do
    event = [:phoenix, :socket_client, :error]
    attach([event])

    Telemetry.emit_event(event, %{count: 1}, %{
      topic: %{payload: @sentinel},
      status: [@sentinel],
      duration: @sentinel,
      pid: @sentinel,
      url: @sentinel,
      error: {:tls_alert, @sentinel}
    })

    assert_receive {:telemetry, ^event, %{count: 1}, metadata}
    assert metadata == %{error: :tls_alert}
  end

  test "error and span telemetry classify failures without exception text, arguments or stacktraces" do
    events =
      for action <- [:start, :stop, :exception], do: [:phoenix, :socket_client, :private, action]

    attach(events)
    payload = %{"private_key" => @sentinel}

    assert {:ok, ^payload} =
             Telemetry.span([:phoenix, :socket_client, :private], %{payload: payload}, fn ->
               {:ok, payload}
             end)

    assert_raise RuntimeError, @sentinel, fn ->
      Telemetry.span([:phoenix, :socket_client, :private], %{error: payload}, fn ->
        raise @sentinel
      end)
    end

    catch_throw(
      Telemetry.span([:phoenix, :socket_client, :private], %{}, fn -> throw(payload) end)
    )

    for _ <- 1..6 do
      assert_receive {:telemetry, _, measurements, metadata}
      refute inspect({measurements, metadata}, limit: :infinity) =~ @sentinel
      refute Map.has_key?(metadata, :stacktrace)
      refute Map.has_key?(metadata, :exception)
    end
  end

  test "reply telemetry is private for both successful and rejected RPCs while replies are delivered" do
    event = [:phoenix, :socket_client, :message, :received]
    attach([event])

    for status <- ["ok", "error"] do
      ref = make_ref()
      call_ref = make_ref()
      response = %{"private_key" => @sentinel}

      message = %Message{
        topic: "agent:runtime",
        event: "phx_reply",
        ref: ref,
        payload: %{"status" => status, "response" => response}
      }

      state = %State{
        topic: message.topic,
        join_ref: "join",
        pushes: [{{self(), call_ref}, %Message{ref: ref}}]
      }

      assert {:noreply, %State{pushes: []}} =
               Helpers.handle_phx_reply_info(message, state, fn _, _, s -> {:noreply, s} end)

      expected = if status == "ok", do: :ok, else: :error
      assert_receive {^call_ref, {^expected, ^response}}

      assert_receive {:telemetry, ^event, _,
                      %{topic: "agent:runtime", event: "phx_reply"} = metadata}

      refute inspect(metadata, limit: :infinity) =~ @sentinel
      refute Map.has_key?(metadata, :payload)
    end
  end

  test "socket status redacts the exact pending state returned by its receive callback" do
    sup =
      start_supervised!(
        {Phoenix.SocketClient.Supervisor,
         [
           name: :privacy_socket,
           auto_connect: false,
           json_library: Jason,
           transport_opts: [ssl: [keyfile: @sentinel]]
         ]}
      )

    socket = Phoenix.SocketClient.get_process_pid(sup, :socket)
    original = :sys.get_state(socket)

    raw =
      Jason.encode!([
        "join",
        "reply",
        "agent:runtime",
        "phx_reply",
        %{"private_key" => @sentinel}
      ])

    assert {:noreply, pending} = Socket.handle_info({:receive, raw}, original)
    :sys.replace_state(socket, fn _ -> pending end)
    refute status_report(:sys.get_status(socket)) =~ @sentinel
    assert :sys.get_state(socket).pending_decodes == pending.pending_decodes
    :sys.replace_state(socket, fn _ -> original end)
    assert_receive {:decode_result, _, {:ok, %Message{payload: %{"private_key" => @sentinel}}}}

    agent = Phoenix.SocketClient.get_process_pid(sup, :socket_state)
    refute status_report(:sys.get_status(agent)) =~ @sentinel
    assert Phoenix.SocketClient.Agent.get(agent, :transport_opts)[:ssl] == [keyfile: @sentinel]
  end

  test "message processor status hides queued encode and decode contents without changing state" do
    processor =
      start_supervised!({MessageProcessor, [serializer: Message.V2, json_library: Jason]})

    original = :sys.get_state(processor)
    queued = %{original | sync_mode: false, batch_interval: 60_000}

    message = %Message{
      topic: "agent:runtime",
      event: "reply",
      payload: %{"private_key" => @sentinel}
    }

    {:reply, :ok, queued} =
      MessageProcessor.handle_call({:enqueue, :encode, message, self(), make_ref()}, nil, queued)

    {:reply, :ok, queued} =
      MessageProcessor.handle_call(
        {:enqueue, :decode, @sentinel, self(), make_ref()},
        nil,
        queued
      )

    :sys.replace_state(processor, fn _ -> queued end)
    refute status_report(:sys.get_status(processor)) =~ @sentinel
    assert :sys.get_state(processor) == queued
    :sys.replace_state(processor, fn _ -> original end)
    Process.cancel_timer(queued.encode_timer)
    Process.cancel_timer(queued.decode_timer)
  end

  test "channel status hides params, pending pushes and custom hook closures while delivery remains intact" do
    payload = %{"private_key" => @sentinel}

    state = %State{
      caller: self(),
      topic: "agent:runtime",
      params: payload,
      pushes: [{nil, %Message{payload: payload}}],
      hooks: %{secret: fn -> payload end}
    }

    channel = start_supervised!({PrivateChannel, state})
    refute status_report(:sys.get_status(channel)) =~ @sentinel
    send(channel, %Message{topic: state.topic, event: "reply", payload: payload})
    assert_receive {:delivered, "reply", ^payload}
    assert :sys.get_state(channel).params == payload
  end

  test "binary pool status omits raw pooled binaries" do
    pool = start_supervised!({Phoenix.SocketClient.BinaryPool, []})
    assert Phoenix.SocketClient.BinaryPool.get_or_pool(pool, @sentinel) == @sentinel
    refute status_report(:sys.get_status(pool)) =~ @sentinel
    assert Phoenix.SocketClient.BinaryPool.get_or_pool(pool, @sentinel) == @sentinel
  end

  test "owned Agent preserves function and MFA get, update, get_and_update and cast calls" do
    agent = start_supervised!({Phoenix.SocketClient.Agent, []})

    assert Agent.get(agent, & &1.status) == :disconnected
    assert :ok = Agent.update(agent, &Map.put(&1, :private, @sentinel))
    assert Agent.get(agent, Map, :get, [:private]) == @sentinel
    assert :ok = Agent.update(agent, Map, :put, [:status, :connected])
    assert Agent.get_and_update(agent, &Map.pop(&1, :private)) == @sentinel
    assert :ok = Agent.cast(agent, &Map.put(&1, :private, @sentinel))
    assert Agent.get_and_update(agent, Map, :pop, [:private]) == @sentinel
    assert :ok = Agent.cast(agent, Map, :put, [:private, @sentinel])
    assert Agent.get(agent, & &1.private) == @sentinel
    refute status_report(:sys.get_status(agent)) =~ @sentinel
  end

  test "adapter status redacts options and errors while preserving WebSocket delivery" do
    alias Phoenix.SocketClient.Transports.HTTPWebSocketAdapter, as: Adapter

    port = Application.fetch_env!(:phoenix_socket_client_test, :port)

    adapter =
      start_supervised!(%{
        id: Adapter,
        start:
          {Adapter, :start_link,
           ["ws://127.0.0.1:#{port}/ws/admin/websocket?vsn=2.0.0", [sender: self()], []]}
      })

    assert_receive {:connected, ^adapter}
    original = :sys.get_state(adapter)

    private = %{
      original
      | tcp_opts: [ssl: [keyfile: @sentinel]],
        url: "wss://user:#{@sentinel}@example.test/socket?token=#{@sentinel}",
        last_error: {:error, @sentinel}
    }

    :sys.replace_state(adapter, fn _ -> private end)
    refute status_report(:sys.get_status(adapter)) =~ @sentinel
    assert :sys.get_state(adapter) == private

    send(
      adapter,
      {HTTP.WebSocket, original.socket, %HTTP.WebSocket.Event.Message{data: @sentinel}}
    )

    assert_receive {:receive, @sentinel}

    event = [:phoenix, :socket_client, :error]
    attach([event])

    send(
      adapter,
      {HTTP.WebSocket, original.socket,
       %HTTP.WebSocket.Event.Error{reason: {:tls_alert, @sentinel}}}
    )

    assert_receive {:telemetry, ^event, _, metadata}
    assert metadata == %{transport: :websocket, event: :websocket_error, error: :tls_alert}
    assert :sys.get_state(adapter).last_error == {:tls_alert, @sentinel}
  end

  test "owned status callbacks redact debug history, messages and reasons" do
    modules = [
      Socket,
      MessageProcessor,
      PrivateChannel,
      Phoenix.SocketClient.Agent,
      Phoenix.SocketClient.BinaryPool,
      Phoenix.SocketClient.Transports.HTTPWebSocketAdapter
    ]

    for module <- modules do
      formatted =
        module.format_status(%{
          state: %{status: :connected, payload: @sentinel},
          message: {:private, @sentinel},
          reason: {:error, @sentinel},
          log: [{:in, @sentinel}]
        })

      assert formatted.state.status == :connected
      assert formatted.reason == :error
      assert formatted.log == []
      refute inspect(formatted, limit: :infinity) =~ @sentinel
    end
  end

  test "OTP channel crash reports redact current payload, state and exception reason" do
    state = %State{caller: self(), topic: "agent:runtime", params: %{"private_key" => @sentinel}}
    {:ok, channel} = PrivateChannel.start_link(state)
    Process.unlink(channel)
    ref = Process.monitor(channel)

    log =
      capture_log(fn ->
        send(channel, %Message{event: "crash", payload: %{"private_key" => @sentinel}})
        assert_receive {:DOWN, ^ref, :process, ^channel, _}
      end)

    assert log =~ "terminating"
    refute log =~ @sentinel
  end

  defp status_report(status) do
    formatted = inspect(status, limit: :infinity)
    refute formatted =~ "format_status/1 crashed"
    formatted
  end

  defp attach(events) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def handle_telemetry(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})
end
