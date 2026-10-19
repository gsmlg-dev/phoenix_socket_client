defmodule Phoenix.SocketClient.UpstreamPrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event.{Message, Open}

  @sentinel "UPSTREAM_PRIVATE_MATERIAL_SENTINEL"
  @timeout 5_000

  test "published transport hides opening URL credentials and TLS options in OTP status" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)

    ws =
      WebSocket.new("ws://127.0.0.1:#{port}/?token=#{@sentinel}", [],
        ssl: [keyfile: "/run/secrets/#{@sentinel}"],
        opening_timeout: 30_000
      )

    {:ok, peer} = :gen_tcp.accept(listener, @timeout)
    on_exit(fn -> :gen_tcp.close(peer) end)
    status = :sys.get_status(ws.pid)
    formatted = inspect(status, limit: :infinity)
    refute formatted =~ @sentinel
    refute :erlang.term_to_binary(status) =~ @sentinel
    refute formatted =~ "format_status/1 crashed"
    assert formatted =~ "ready_state"
    assert WebSocket.ready_state(ws) == WebSocket.connecting()
    close_connection(ws)
  end

  test "published transport hides private parser and delivery queues without changing replies" do
    ws = open_connection()
    original = :sys.get_state(ws.pid)

    private = %{
      original
      | parser: %{original.parser | buffer: @sentinel},
        raw_queue: :queue.from_list([@sentinel]),
        delivery: %{original.delivery | queue: :queue.from_list([@sentinel])}
    }

    :sys.replace_state(ws.pid, fn _ -> private end)
    status = :sys.get_status(ws.pid)
    refute inspect(status, limit: :infinity) =~ @sentinel
    refute :erlang.term_to_binary(status) =~ @sentinel
    assert :sys.get_state(ws.pid) == private
    :sys.replace_state(ws.pid, fn _ -> original end)

    payload = %{"private_key" => @sentinel}

    assert :ok =
             WebSocket.send(
               ws,
               Jason.encode!(["join", "reply", "rooms:reply", "phx_join", payload])
             )

    assert_receive {WebSocket, ^ws, %Message{data: data}}, @timeout

    assert [
             "join",
             "reply",
             "rooms:reply",
             "phx_reply",
             %{"response" => ^payload, "status" => "ok"}
           ] =
             Jason.decode!(data)

    close_connection(ws)
  end

  test "published transport termination hides callback arguments and queued messages in raw reports" do
    ws = open_connection()
    owner = self()

    # Observe raw events before formatting; the filter leaves every event intact.
    observer = fn event, pid ->
      send(pid, {:upstream_log, event})
      :ignore
    end

    :ok = :logger.add_primary_filter(__MODULE__, {observer, owner})
    on_exit(fn -> :logger.remove_primary_filter(__MODULE__) end)
    monitor = Process.monitor(ws.pid)
    pid = ws.pid

    log =
      capture_log(fn ->
        :ok = :sys.log(pid, true)
        send(pid, {:private_history, @sentinel})
        _ = :sys.get_state(pid)
        :ok = :sys.suspend(pid)
        send(pid, {:"$gen_call", {self(), make_ref()}, {:unexpected_private_call, @sentinel}})
        send(pid, {:private_queued, @sentinel})
        :ok = :sys.resume(pid)

        assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, @timeout
        assert_receive {:upstream_log, %{meta: %{pid: ^pid}} = report}, @timeout
        assert {:report, %{label: {:gen_server, :terminate}}} = report.msg
        refute inspect(report, limit: :infinity) =~ @sentinel
        refute :erlang.term_to_binary(report) =~ @sentinel
      end)

    assert log =~ "terminating"
    refute log =~ @sentinel
    assert_private_reports()
  end

  defp open_connection do
    port = Application.fetch_env!(:phoenix_socket_client_test, :port)

    ws =
      WebSocket.new("ws://127.0.0.1:#{port}/ws/admin/websocket?vsn=2.0.0&token=#{@sentinel}", [],
        ssl: [keyfile: "/run/secrets/#{@sentinel}"]
      )

    assert_receive {WebSocket, ^ws, %Open{}}, @timeout
    ws
  end

  defp close_connection(ws) do
    monitor = Process.monitor(ws.pid)
    assert :ok = WebSocket.close(ws)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, @timeout
  end

  defp assert_private_reports do
    receive do
      {:upstream_log, report} ->
        refute inspect(report, limit: :infinity) =~ @sentinel
        refute :erlang.term_to_binary(report) =~ @sentinel
        assert_private_reports()
    after
      0 -> :ok
    end
  end
end
