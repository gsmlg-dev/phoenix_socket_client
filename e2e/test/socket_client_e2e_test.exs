defmodule PhoenixSocketClientE2E.CaptureChannel do
  use Phoenix.SocketClient.Channel

  @impl true
  def handle_message(event, payload, state) do
    if caller = Application.get_env(:phoenix_socket_client_e2e, :capture_pid) do
      send(caller, {state.topic, event, payload})
    end

    {:noreply, state}
  end
end

defmodule PhoenixSocketClientE2E.SocketClientTest do
  use ExUnit.Case, async: false

  alias Phoenix.SocketClient.Channel

  @transports [
    {:websocket, Phoenix.SocketClient.Transports.Websocket},
    {:optimized_websocket, Phoenix.SocketClient.Transports.OptimizedWebsocket}
  ]

  setup do
    Application.put_env(:phoenix_socket_client_e2e, :capture_pid, self())
    :ok
  end

  describe "transport compatibility" do
    for {transport_name, transport} <- @transports do
      @transport_name transport_name
      @transport transport

      test "#{transport_name} connects, joins, pushes, receives, and leaves" do
        name = unique_name(@transport_name)

        {:ok, sup} =
          start_client(
            name,
            transport: @transport,
            default_channel_module: PhoenixSocketClientE2E.CaptureChannel,
            params: %{"client" => Atom.to_string(@transport_name)},
            headers: [{"x-e2e-client", Atom.to_string(@transport_name)}]
          )

        assert_connected(name)

        assert {:ok, connect_info, connect_info_pid} =
                 Channel.join(sup, "rooms:connect_info", %{"join" => "ok"})

        assert connect_info["headers"]["x-e2e-client"] == Atom.to_string(@transport_name)
        assert connect_info["params"]["client"] == Atom.to_string(@transport_name)
        assert connect_info["join"] == %{"join" => "ok"}

        assert {:ok, reply, channel_pid} =
                 Channel.join(sup, "rooms:lobby", %{"user" => Atom.to_string(@transport_name)})

        assert reply == %{"user" => Atom.to_string(@transport_name)}
        assert_receive {"rooms:lobby", "user:entered", %{"user" => user}}, 1_000
        assert user == Atom.to_string(@transport_name)

        assert {:ok, %{"ping" => "pong"}} = Channel.push(channel_pid, "ping", %{})

        payload = %{"body" => "hello", "transport" => Atom.to_string(@transport_name)}
        assert {:ok, ^payload} = Channel.push(channel_pid, "new:msg", payload)
        assert_receive {"rooms:lobby", "new:msg", ^payload}, 1_000

        assert :ok = Channel.leave(channel_pid)
        refute Process.alive?(channel_pid)

        assert :ok = Channel.leave(connect_info_pid)
      end
    end
  end

  test "manual connect mode connects only when requested" do
    name = unique_name(:manual_connect)

    {:ok, _sup} =
      start_client(
        name,
        auto_connect: false,
        reconnect: false,
        transport: Phoenix.SocketClient.Transports.Websocket
      )

    refute Phoenix.SocketClient.connected?(name)

    assert :ok = Phoenix.SocketClient.connect(name)
    assert_connected(name)
  end

  test "initial channel list is auto-joined after connect" do
    name = unique_name(:auto_join)
    topics = ["auto:first", "auto:second"]

    {:ok, _sup} =
      start_client(
        name,
        join_channels: topics,
        transport: Phoenix.SocketClient.Transports.OptimizedWebsocket
      )

    assert_connected(name)

    assert_eventually(fn ->
      joined = Phoenix.SocketClient.get_state(name, :joined_channels)
      Enum.all?(topics, &(get_in(joined, [&1, :status]) == :joined))
    end)
  end

  test "default channel module, default params, and topic channel map dispatch messages" do
    name = unique_name(:custom_channels)

    {:ok, sup} =
      start_client(
        name,
        default_channel_module: PhoenixSocketClientE2E.CaptureChannel,
        default_channel_params: %{"default" => "param"},
        topic_channel_map: %{
          "custom:topic" => PhoenixSocketClientE2E.CaptureChannel
        }
      )

    assert_connected(name)

    assert {:ok, reply, test_pid} =
             Channel.join(sup, "test:topic", %{"local" => "param"})

    assert reply["default"] == "param"
    assert reply["local"] == "param"

    payload = %{"source" => "default-channel"}
    assert {:ok, ^payload} = Channel.push(test_pid, "test_event", payload)
    assert_receive {"test:topic", "test_event", ^payload}, 1_000

    assert {:ok, reply, custom_pid} =
             Channel.join(sup, "custom:topic", %{"custom" => "param"})

    assert reply["custom"] == "param"
    assert reply["default"] == "param"

    payload = %{"source" => "topic-map"}
    assert {:ok, ^payload} = Channel.push(custom_pid, "test_event", payload)
    assert_receive {"custom:topic", "test_event", ^payload}, 1_000
  end

  test "join error and timeout paths return client errors" do
    name = unique_name(:errors)

    {:ok, sup} = start_client(name)
    assert_connected(name)

    assert {:error, %{"reason" => "join failed"}} =
             Channel.join(sup, "topic:fail", %{"reason" => "expected"})

    assert {:error, :timeout} =
             Channel.join(sup, "rooms:join_timeout", %{"slow" => true}, 10)
  end

  test "push timeout returns a client timeout without crashing the channel" do
    name = unique_name(:push_timeout)

    {:ok, sup} = start_client(name)
    assert_connected(name)

    assert {:ok, _reply, channel_pid} = Channel.join(sup, "rooms:reply")
    assert catch_exit(Channel.push(channel_pid, "foo:bar", %{}, 10))
    assert Process.alive?(channel_pid)
  end

  test "connected channels rejoin after transport disconnect" do
    name = unique_name(:reconnect)

    {:ok, sup} =
      start_client(
        name,
        reconnect: true,
        reconnect_interval: 25,
        transport: Phoenix.SocketClient.Transports.Websocket
      )

    assert_connected(name)

    assert {:ok, _reply, _channel_pid} =
             Channel.join(sup, "topic:rejoin", %{"generation" => "one"})

    assert_eventually(fn ->
      get_in(Phoenix.SocketClient.get_state(name, :joined_channels), ["topic:rejoin", :status]) ==
        :joined
    end)

    transport_pid = Phoenix.SocketClient.get_process_pid(name, :socket) |> current_transport_pid()
    assert is_pid(transport_pid)
    Process.exit(transport_pid, :kill)

    assert_connected(name)

    assert_eventually(fn ->
      channel_data =
        get_in(Phoenix.SocketClient.get_state(name, :joined_channels), ["topic:rejoin"])

      channel_data && channel_data.status == :joined &&
        channel_data.params == %{"generation" => "one"}
    end)
  end

  test "disconnect marks the client disconnected" do
    name = unique_name(:disconnect)

    {:ok, _sup} = start_client(name, reconnect: false)
    assert_connected(name)

    assert :ok = Phoenix.SocketClient.disconnect(name)

    assert_eventually(fn ->
      Phoenix.SocketClient.connected?(name) == false
    end)
  end

  defp start_client(name, opts \\ []) do
    Phoenix.SocketClient.start_link(
      Keyword.merge(
        [
          name: name,
          url: server_url(),
          reconnect_interval: 50
        ],
        opts
      )
    )
  end

  defp assert_connected(name) do
    assert_eventually(fn -> Phoenix.SocketClient.connected?(name) end)
  end

  defp assert_eventually(fun, attempts \\ 80)

  defp assert_eventually(_fun, 0) do
    flunk("condition did not become true")
  end

  defp assert_eventually(fun, attempts) do
    if fun.() do
      assert true
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp current_transport_pid(socket_pid) do
    socket_pid
    |> :sys.get_state()
    |> Map.fetch!(:transport_pid)
  end

  defp server_url do
    "ws://127.0.0.1:#{Application.fetch_env!(:phoenix_socket_client_e2e, :port)}/ws/admin/websocket"
  end

  defp unique_name(prefix) do
    :"e2e_#{prefix}_#{System.unique_integer([:positive])}"
  end
end
