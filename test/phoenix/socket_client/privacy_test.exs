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

  defmodule CleanupFailureChannel do
    use Phoenix.SocketClient.Channel

    def init(state), do: {:ok, state}
    @impl true
    def handle_message(_, _, state), do: {:noreply, state}
    def terminate(_, state), do: raise(state.params["private_key"])
  end

  defmodule RawLogger do
    def log(event, %{config: %{owner: owner}}), do: send(owner, {:raw_log, event})
  end

  defmodule InitFailureChannel do
    use Phoenix.SocketClient.Channel

    def init({mode, owner, private}) do
      send(owner, {:initializing, self()})

      receive do
        :continue ->
          case mode do
            :raise -> raise private
            :throw -> throw(private)
            :exit -> exit(private)
            :stop -> {:stop, {:private, private}}
            :bad_return -> {:private, private}
            :bad_action -> {:ok, %{private: private}, {:timeout, private, :message}}
            :ignore -> :ignore
            :normal_stop -> {:stop, :normal}
            :shutdown_stop -> {:stop, :shutdown}
          end
      end
    end

    @impl true
    def handle_message(_, _, state), do: {:noreply, state}
  end

  defmodule LifecycleChannel do
    use Phoenix.SocketClient.Channel

    def init(args) do
      {:ok, state} = Helpers.init_impl(args)
      send(state.params["owner"], {:channel_started, self()})
      {:ok, state}
    end

    @impl true
    def handle_message("crash", payload, _state), do: raise(payload["private_key"])
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
      Phoenix.SocketClient.HibernationManager,
      Phoenix.SocketClient.RouteCache,
      Phoenix.SocketClient.PerformanceMonitor,
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
        assert_receive {:DOWN, ^ref, :process, ^channel, :private_callback_failure}
      end)

    assert log =~ "terminating"
    refute log =~ @sentinel
  end

  test "FunctionClauseError termination omits callback arguments and queued private messages" do
    sup =
      start_supervised!(
        {Phoenix.SocketClient.Supervisor, [name: :privacy_crash_socket, auto_connect: false]}
      )

    port = Application.fetch_env!(:phoenix_socket_client_test, :port)
    alias Phoenix.SocketClient.Transports.HTTPWebSocketAdapter, as: Adapter

    starters = [
      fn -> Socket.start_link(sup_pid: sup) end,
      fn -> MessageProcessor.start_link(serializer: Message.V2) end,
      fn -> Phoenix.SocketClient.Agent.start_link(private_key: @sentinel) end,
      fn -> Phoenix.SocketClient.BinaryPool.start_link([]) end,
      fn -> Phoenix.SocketClient.HibernationManager.start_link([]) end,
      fn -> Phoenix.SocketClient.RouteCache.start_link([]) end,
      fn -> Phoenix.SocketClient.PerformanceMonitor.start_link([]) end,
      fn -> PrivateChannel.start_link(%State{params: %{"private_key" => @sentinel}}) end,
      fn ->
        Adapter.start_link(
          "ws://127.0.0.1:#{port}/ws/admin/websocket?vsn=2.0.0",
          sender: self()
        )
      end
    ]

    for start <- starters do
      assert_private_crash(start, {:unexpected_private_call, @sentinel})
    end
  end

  test "Agent function and MFA failures hide private state and callback arguments" do
    for operation <- [:get, :update, :get_and_update] do
      for callback <- [
            fn state -> raise state.custom.private_key end,
            {String, :to_integer, [@sentinel]}
          ] do
        assert_private_crash(
          fn -> Phoenix.SocketClient.Agent.start_link(private_key: @sentinel) end,
          {operation, callback}
        )
      end
    end

    for callback <- [
          fn state -> raise state.custom.private_key end,
          {String, :to_integer, [@sentinel]}
        ] do
      assert_private_crash(
        fn -> Phoenix.SocketClient.Agent.start_link(private_key: @sentinel) end,
        {:cast, callback},
        :cast
      )
    end
  end

  test "overridden Channel cleanup failures hide private exception text" do
    assert_private_crash(
      fn -> CleanupFailureChannel.start_link(%State{params: %{"private_key" => @sentinel}}) end,
      {:unexpected_private_call, @sentinel}
    )
  end

  test "normal and shutdown process stops retain their exit reason" do
    for reason <- [:normal, :shutdown] do
      {:ok, agent} = Phoenix.SocketClient.Agent.start_link([])
      Process.unlink(agent)
      ref = Process.monitor(agent)
      assert :ok = GenServer.stop(agent, reason)
      assert_receive {:DOWN, ^ref, :process, ^agent, ^reason}
    end
  end

  test "abnormal transport exits disconnect the Socket without terminating it" do
    sup =
      start_supervised!(
        {Phoenix.SocketClient.Supervisor,
         [name: :privacy_transport_exit, auto_connect: false, reconnect: false]}
      )

    socket = Phoenix.SocketClient.get_process_pid(sup, :socket)
    transport = self()
    :sys.replace_state(socket, &%{&1 | transport_pid: transport, status: :connected})
    send(socket, {:EXIT, transport, {:transport_failed, @sentinel}})
    assert GenServer.call(socket, :get_status) == :disconnected
    assert Process.alive?(socket)
  end

  test "overridden init failures hide private arguments, reasons and queued messages" do
    for mode <- [:raise, :throw, :exit, :stop, :bad_return, :bad_action] do
      owner = self()
      id = __MODULE__.RawLogger
      :ok = :logger.add_handler(id, RawLogger, %{level: :all, config: %{owner: owner}})

      log =
        try do
          capture_log(fn ->
            starter =
              Task.async(fn ->
                Process.flag(:trap_exit, true)
                InitFailureChannel.start_link({mode, owner, @sentinel})
              end)

            assert_receive {:initializing, pid}
            ref = Process.monitor(pid)
            send(pid, {:queued_private_message, @sentinel})
            send(pid, :continue)
            assert Task.await(starter) == {:error, :private_callback_failure}
            assert_receive {:DOWN, ^ref, :process, ^pid, :private_callback_failure}
            Logger.flush()
          end)
        after
          :logger.remove_handler(id)
        end

      assert log =~ "terminating"
      refute log =~ @sentinel
      events = raw_logs([])
      assert events != []
      refute :erlang.term_to_binary(events) =~ @sentinel
    end
  end

  test "Agent init failures return a private error classification" do
    log =
      capture_log(fn ->
        starter =
          Task.async(fn ->
            Process.flag(:trap_exit, true)
            Phoenix.SocketClient.Agent.start_link(url: @sentinel, params: @sentinel)
          end)

        assert Task.await(starter) == {:error, :private_callback_failure}
      end)

    assert log =~ "terminating"
    refute log =~ @sentinel
  end

  test "overridden init preserves ignore and orderly stop results" do
    owner = self()

    for {mode, expected} <- [
          {:ignore, :ignore},
          {:normal_stop, {:error, :normal}},
          {:shutdown_stop, {:error, :shutdown}}
        ] do
      starter =
        Task.async(fn ->
          Process.flag(:trap_exit, true)
          InitFailureChannel.start_link({mode, owner, @sentinel})
        end)

      assert_receive {:initializing, pid}
      send(pid, :continue)
      assert Task.await(starter) == expected
    end
  end

  test "async worker Task failures omit batch arguments and queued private messages" do
    processor =
      start_supervised!(
        {MessageProcessor, [serializer: Message.V2, sync_mode: false, concurrency: 1]}
      )

    %{worker_sup: worker_sup} = :sys.get_state(processor)
    [{_, worker, :worker, _}] = Supervisor.which_children(worker_sup)
    ref = Process.monitor(worker)
    id = __MODULE__.RawLogger
    :ok = :logger.add_handler(id, RawLogger, %{level: :all, config: %{owner: self()}})

    log =
      try do
        capture_log(fn ->
          :erlang.suspend_process(worker)
          send(worker, {:encode_batch, [{:invalid_batch_item, @sentinel}], self()})
          send(worker, {:queued_private_message, @sentinel})
          :erlang.resume_process(worker)
          assert_receive {:DOWN, ^ref, :process, ^worker, :private_callback_failure}
          Logger.flush()
        end)
      after
        :logger.remove_handler(id)
        if Process.alive?(worker_sup), do: Supervisor.stop(worker_sup)
      end

    assert log =~ "terminating"
    refute log =~ @sentinel
    events = raw_logs([])
    assert events != []
    refute :erlang.term_to_binary(events) =~ @sentinel
  end

  test "supervised private channel failures restart while explicit leaves stay stopped" do
    sup =
      start_supervised!(
        {Phoenix.SocketClient.Supervisor,
         [name: :privacy_channel_lifecycle, auto_connect: false, reconnect: false]}
      )

    id = __MODULE__.RawLogger
    :ok = :logger.add_handler(id, RawLogger, %{level: :all, config: %{owner: self()}})

    log =
      try do
        capture_log(fn ->
          {:ok, channel} =
            Phoenix.SocketClient.ChannelManager.start_channel(
              sup,
              "privacy:lifecycle",
              %{"owner" => self(), "private_key" => @sentinel},
              LifecycleChannel
            )

          assert_receive {:channel_started, ^channel}
          ref = Process.monitor(channel)
          :sys.suspend(channel)
          send(channel, %Message{event: "crash", payload: %{"private_key" => @sentinel}})
          send(channel, {:queued_private_message, @sentinel})
          :sys.resume(channel)
          assert_receive {:DOWN, ^ref, :process, ^channel, :private_callback_failure}
          assert_receive {:channel_started, replacement}
          assert replacement != channel
          ref = Process.monitor(replacement)
          assert Phoenix.SocketClient.Channel.leave(replacement) == :ok
          assert_receive {:DOWN, ^ref, :process, ^replacement, :normal}

          manager = Phoenix.SocketClient.get_process_pid(sup, :channel_manager)
          assert DynamicSupervisor.count_children(manager).active == 0
          refute_receive {:channel_started, _}
          Logger.flush()
        end)
      after
        :logger.remove_handler(id)
      end

    assert log =~ "terminating"
    refute log =~ @sentinel
    events = raw_logs([])
    assert events != []
    refute :erlang.term_to_binary(events) =~ @sentinel
  end

  defp assert_private_crash(start, request, kind \\ :call) do
    {:ok, pid} = start.()
    Process.unlink(pid)
    ref = Process.monitor(pid)
    id = __MODULE__.RawLogger
    :ok = :logger.add_handler(id, RawLogger, %{level: :all, config: %{owner: self()}})

    log =
      try do
        capture_log(fn ->
          :ok = :sys.suspend(pid)

          case kind do
            :call -> send(pid, {:"$gen_call", {self(), make_ref()}, request})
            :cast -> send(pid, {:"$gen_cast", request})
          end

          send(pid, {:queued_private_message, @sentinel})
          :ok = :sys.resume(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, :private_callback_failure}
          Logger.flush()
        end)
      after
        :logger.remove_handler(id)
      end

    assert log =~ "terminating"
    refute log =~ @sentinel
    events = raw_logs([])
    assert Enum.any?(events, &match?(%{meta: %{pid: ^pid}}, &1))
    refute :erlang.term_to_binary(events) =~ @sentinel
  end

  defp raw_logs(events) do
    receive do
      {:raw_log, event} -> raw_logs([event | events])
    after
      0 -> events
    end
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
