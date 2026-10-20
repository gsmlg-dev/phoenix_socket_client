defmodule Phoenix.SocketClient.ConnectionInfoTest do
  use ExUnit.Case, async: false

  alias Phoenix.SocketClient, as: Client
  alias Phoenix.SocketClient.Telemetry
  alias Phoenix.SocketClient.Transports.{OptimizedWebsocket, Websocket}

  defmodule ControlledTransport do
    @behaviour Phoenix.SocketClient.Transport

    def open(_url, opts) do
      owner = Keyword.fetch!(opts, :owner)
      sender = Keyword.fetch!(opts, :sender)

      case Keyword.get(opts, :error) do
        nil ->
          pid = spawn(fn -> loop(owner, sender) end)
          send(owner, {:opened, pid})
          {:ok, pid}

        error ->
          send(owner, {:open_failed, error})
          {:error, error}
      end
    end

    def close(pid) do
      send(pid, :close)
      :ok
    end

    defp loop(owner, sender) do
      receive do
        :connect ->
          send(sender, {:connected, self()})
          loop(owner, sender)

        :close ->
          send(owner, {:closed, self()})
      end
    end
  end

  setup do
    old_config = Application.get_env(:phoenix_socket_client, :telemetry)

    on_exit(fn ->
      if old_config,
        do: Application.put_env(:phoenix_socket_client, :telemetry, old_config),
        else: Application.delete_env(:phoenix_socket_client, :telemetry)
    end)

    :ok
  end

  for {configuration, mode} <- [
        {%{enabled: false}, "disabled"},
        {%{enabled: true, sampler_rate: 0.0}, "unsampled"}
      ],
      transport <- [Websocket, OptimizedWebsocket],
      status <- [401, 403] do
    @configuration configuration
    @transport transport
    @status status

    test "retains HTTP #{status} using #{inspect(transport)} with telemetry #{mode}" do
      Telemetry.update_config(@configuration)
      attach_telemetry()
      {port, server} = http_fixture(@status)
      root = start_client(url: "ws://127.0.0.1:#{port}/socket", transport: @transport)

      assert %{attempt_ref: nil, status: :disconnected, last_error: nil} =
               Client.connection_info(root)

      assert :ok = Client.connect(root)
      assert_receive {:served, ^server, @status}, 5_000
      result = await_info(root, :disconnected)
      assert %{attempt_ref: ref, last_error: {:unexpected_status, @status}} = result
      assert is_reference(ref)
      assert Client.connection_info(root) == result
      refute Client.connected?(root)
      refute_receive {:connection_telemetry, _}, 30
    end
  end

  test "retains real connection refusal separately from authentication rejection" do
    Telemetry.update_config(%{enabled: false})
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    root = start_client(url: "ws://127.0.0.1:#{port}/socket")
    assert :ok = Client.connect(root)
    assert %{last_error: :econnrefused} = await_info(root, :disconnected)
  end

  test "retains a real opening timeout independently of telemetry sampling" do
    Telemetry.update_config(%{enabled: true, sampler_rate: 0.0})
    {port, server} = http_fixture(:stall)

    root =
      start_client(
        url: "ws://127.0.0.1:#{port}/socket",
        transport_opts: [timeout: 100, connect_timeout: 100]
      )

    assert :ok = Client.connect(root)
    assert_receive {:served, ^server, :stall}, 5_000
    assert %{last_error: reason} = await_info(root, :disconnected)
    assert reason in [:timeout, :opening_timeout]
  end

  test "cancellation invalidates the old transport while a newer attempt succeeds" do
    root = controlled_client(reconnect: true)
    assert :ok = Client.connect(root)
    assert_receive {:opened, old_transport}
    assert %{attempt_ref: old_ref, status: :connecting} = Client.connection_info(root)
    socket = Client.get_process_pid(root, :socket)
    old_monitor = GenServer.call(socket, :get_state).transport_ref

    assert :ok = Client.disconnect(root)

    assert %{attempt_ref: ^old_ref, status: :disconnected, last_error: :cancelled} =
             Client.connection_info(root)

    assert_receive {:closed, ^old_transport}
    assert :ok = Client.connect(root)
    assert_receive {:opened, transport}

    assert %{attempt_ref: new_ref, status: :connecting, last_error: nil} =
             Client.connection_info(root)

    refute new_ref == old_ref
    send(transport, :connect)
    assert %{attempt_ref: ^new_ref, last_error: nil} = await_info(root, :connected)
    send(socket, {:connected, old_transport})
    send(socket, {:disconnected, {:unexpected_status, 403}, old_transport})
    send(socket, {:closed, :stale, old_transport})
    send(socket, {:EXIT, old_transport, :stale})
    send(socket, {:DOWN, old_monitor, :process, old_transport, :stale})

    assert %{attempt_ref: ^new_ref, status: :connected, last_error: nil} =
             Client.connection_info(root)

    assert :ok = Client.disconnect(root)
    assert_receive {:closed, ^transport}
  end

  test "disconnect cancels a scheduled retry and its attempt result remains cancelled" do
    root =
      controlled_client(reconnect: true, transport_opts: [owner: self(), error: :econnrefused])

    assert :ok = Client.connect(root)
    assert_receive {:open_failed, :econnrefused}
    assert %{attempt_ref: ref, last_error: :econnrefused} = await_info(root, :disconnected)
    socket = Client.get_process_pid(root, :socket)
    {_timer, old_token} = GenServer.call(socket, :get_state).connect_timer
    assert :ok = Client.disconnect(root)

    assert %{attempt_ref: ^ref, status: :disconnected, last_error: :cancelled} =
             Client.connection_info(root)

    send(socket, {:connect, old_token})
    refute_receive {:open_failed, _}, 200
    assert %{attempt_ref: ^ref, last_error: :cancelled} = Client.connection_info(root)
    assert Client.get_state(root, :reconnecting) == false
  end

  test "disconnect cancels the delayed initial auto-connect" do
    root = controlled_client(auto_connect: true, reconnect: true)
    socket = Client.get_process_pid(root, :socket)
    {_timer, old_token} = GenServer.call(socket, :get_state).connect_timer
    assert :ok = Client.disconnect(root)
    assert %{attempt_ref: nil, status: :disconnected} = Client.connection_info(root)
    send(socket, {:connect, old_token})
    refute_receive {:opened, _}, 1_100
  end

  test "automatic retries allocate a new attempt reference" do
    root =
      controlled_client(reconnect: true, transport_opts: [owner: self(), error: :econnrefused])

    assert :ok = Client.connect(root)
    assert_receive {:open_failed, :econnrefused}
    assert %{attempt_ref: first, last_error: :econnrefused} = await_info(root, :disconnected)
    assert_receive {:open_failed, :econnrefused}
    assert %{attempt_ref: second, last_error: :econnrefused} = await_info(root, :disconnected)
    refute first == second
    assert :ok = Client.disconnect(root)
    assert %{last_error: :cancelled} = Client.connection_info(root)
    refute_receive {:open_failed, _}, 200
  end

  test "duplicate connect requests preserve the attempt and duplicate success preserves heartbeat" do
    root = controlled_client([])
    assert :ok = Client.connect(root)
    assert_receive {:opened, transport}
    assert %{attempt_ref: ref, status: :connecting} = Client.connection_info(root)
    assert :ok = Client.connect(root)
    assert %{attempt_ref: ^ref, status: :connecting} = Client.connection_info(root)
    refute_receive {:opened, _}, 30
    send(transport, :connect)
    assert %{attempt_ref: ^ref} = await_info(root, :connected)
    socket = Client.get_process_pid(root, :socket)
    heartbeat = GenServer.call(socket, :get_state).heartbeat_timer
    send(socket, {:connected, transport})
    assert %{attempt_ref: ^ref, status: :connected} = Client.connection_info(root)
    assert GenServer.call(socket, :get_state).heartbeat_timer == heartbeat
    assert :ok = Client.disconnect(root)
    assert_receive {:closed, ^transport}
  end

  test "structured failures expose categories without private details" do
    sentinel = "CONNECTION_INFO_PRIVATE_SENTINEL"
    root = controlled_client(transport_opts: [owner: self(), error: {:tls_alert, sentinel}])
    assert :ok = Client.connect(root)
    info = await_info(root, :disconnected)
    assert %{last_error: :tls_alert} = info
    refute inspect(info, limit: :infinity) =~ sentinel
    refute :erlang.term_to_binary(info) =~ sentinel

    assert :ok =
             Client.put_state(root, :transport_opts, owner: self(), error: %{private: sentinel})

    assert :ok = Client.connect(root)
    assert %{last_error: :transport_error} = await_info(root, :disconnected)
    assert :ok = Client.disconnect(root)
  end

  @tag :reconnect_alias
  test "the documented reconnect? option disables retries" do
    root =
      start_supervised!(
        {Client,
         name: :"connection_alias_#{System.unique_integer([:positive])}",
         url: "ws://example.invalid/socket",
         auto_connect: false,
         reconnect?: false,
         reconnect_interval: 50,
         transport: ControlledTransport,
         transport_opts: [owner: self(), error: :econnrefused]}
      )

    assert Client.get_state(root, :reconnect) == false
    assert :ok = Client.connect(root)
    assert_receive {:open_failed, :econnrefused}
    assert %{last_error: :econnrefused} = await_info(root, :disconnected)
    refute_receive {:open_failed, _}, 150
  end

  test "a newer successful attempt clears a retained synchronous failure" do
    root = controlled_client(transport_opts: [owner: self(), error: :econnrefused])
    assert :ok = Client.connect(root)
    assert %{attempt_ref: old_ref, last_error: :econnrefused} = await_info(root, :disconnected)
    assert :ok = Client.put_state(root, :transport_opts, owner: self())
    assert :ok = Client.connect(root)
    assert_receive {:opened, transport}
    send(transport, :connect)

    assert %{attempt_ref: new_ref, status: :connected, last_error: nil} =
             await_info(root, :connected)

    refute new_ref == old_ref
    assert :ok = Client.disconnect(root)
    assert_receive {:closed, ^transport}
  end

  test "missing clients have no connection snapshot" do
    assert {:error, :no_socket_found} = Client.connection_info(:nonexistent_connection_info)
  end

  def telemetry_event(event, _measurements, _metadata, owner),
    do: send(owner, {:connection_telemetry, event})

  defp attach_telemetry do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:phoenix, :socket_client, :connection, :error],
          [:phoenix, :socket_client, :connection, :established, :stop]
        ],
        &__MODULE__.telemetry_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp controlled_client(opts) do
    start_client(
      Keyword.merge([transport: ControlledTransport, transport_opts: [owner: self()]], opts)
    )
  end

  defp start_client(opts) do
    opts =
      Keyword.merge(
        [
          name: :"connection_info_#{System.unique_integer([:positive])}",
          url: "ws://example.invalid/socket",
          auto_connect: false,
          reconnect: false,
          reconnect_interval: 100
        ],
        opts
      )

    start_supervised!({Client, opts})
  end

  defp http_fixture(response) do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      start_supervised!(
        {Task,
         fn ->
           {:ok, peer} = :gen_tcp.accept(listener)
           {:ok, _request} = :gen_tcp.recv(peer, 0, 5_000)
           send(owner, {:served, self(), response})

           if response == :stall do
             :gen_tcp.recv(peer, 0, 5_000)
           else
             :gen_tcp.send(
               peer,
               "HTTP/1.1 #{response} Fixture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
             )
           end

           :gen_tcp.close(peer)
         end},
        id: make_ref(),
        restart: :temporary
      )

    {port, server}
  end

  defp await_info(root, status, remaining \\ 500)

  defp await_info(root, _status, 0),
    do: flunk("connection did not settle: #{inspect(Client.connection_info(root))}")

  defp await_info(root, status, remaining) do
    case Client.connection_info(root) do
      %{attempt_ref: ref, status: ^status} = info when is_reference(ref) ->
        info

      _ ->
        Process.sleep(10)
        await_info(root, status, remaining - 1)
    end
  end
end
