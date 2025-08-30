defmodule PhoenixSocketClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn, except: [assign: 3, push: 3]

  alias __MODULE__.Endpoint
  alias PhoenixSocketClient.{Socket, Channel, Message}

  require Logger

  @port 5807

  Application.put_env(:phoenix, :json_library, Jason)

  Application.put_env(
    :channel_app,
    Endpoint,
    https: false,
    http: [port: @port],
    secret_key_base: String.duplicate("abcdefgh", 8),
    debug_errors: false,
    code_reloader: false,
    server: true,
    pubsub: [adapter: Phoenix.PubSub.PG2, name: :int_pub]
  )

  @socket_config [
    url: "ws://127.0.0.1:#{@port}/ws/admin/websocket",
    serializer: Jason,
    reconnect_interval: 10
  ]

  defmodule RoomChannel do
    use Phoenix.Channel
    require Logger

    def join("rooms:headers", _message, socket) do
      {:ok, socket.assigns.headers, socket}
    end

    def join("rooms:join_timeout", message, socket) do
      :timer.sleep(50)
      {:ok, message, socket}
    end

    def join("rooms:reply", message, socket) do
      {:ok, message, socket}
    end

    def join(topic, message, socket) do
      Process.flag(:trap_exit, true)
      Process.register(self(), String.to_atom(topic))
      send(self(), {:after_join, message})
      {:ok, socket}
    end

    def handle_info({:after_join, message}, socket) do
      broadcast(socket, "user:entered", %{user: message["user"]})
      push(socket, "joined", Map.merge(%{status: "connected"}, socket.assigns))
      {:noreply, socket}
    end

    def handle_info(_, socket) do
      {:noreply, socket}
    end

    def handle_in("new:msg", message, socket) do
      {:reply, {:ok, message}, socket}
    end

    def handle_in("boom", _message, _socket) do
      raise "boom"
    end

    def handle_in(_, _message, socket) do
      {:noreply, socket}
    end

    def terminate(_reason, socket) do
      push(socket, "you:left", %{message: "bye!"})
      :ok
    end
  end

  defmodule Router do
    use Phoenix.Router
  end

  defmodule UserSocket do
    use Phoenix.Socket

    channel("rooms:*", RoomChannel)

    def connect(%{"reject" => reject}, _socket, _connect_info) when reject in ["true", true] do
      :error
    end

    def connect(params, socket, %{x_headers: headers}) do
      socket =
        socket
        |> assign(:user_id, params["user_id"])
        |> assign(:headers, encode_headers(headers))

      {:ok, socket}
    end

    def id(socket) do
      if id = socket.assigns.user_id, do: "user_sockets:#{id}"
    end

    defp encode_headers(headers) do
      Enum.reduce(headers, %{}, fn {k, v}, acc -> Map.put(acc, k, v) end)
    end
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :channel_app

    def call(conn, opts) do
      Logger.disable(self())
      super(conn, opts)
    end

    socket("/ws", UserSocket, websocket: [check_origin: false, connect_info: [:x_headers]])

    socket("/ws/admin", UserSocket, websocket: [check_origin: false, connect_info: [:x_headers]])

    plug(
      Plug.Parsers,
      parsers: [:urlencoded, :json],
      pass: "*/*",
      json_decoder: Jason
    )

    plug(
      Plug.Session,
      store: :cookie,
      key: "_integration_test",
      encryption_salt: "yadayada",
      signing_salt: "yadayada"
    )

    plug(Router)
  end

  setup_all do
    Application.ensure_all_started(:bandit)
    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:jason)
    start_endpoint()
    :ok
  end

  setup do
    start_supervised({Registry, keys: :unique, name: Registry.Connection})
    start_supervised({PhoenixSocketClient, name: PhoenixSocketClient})
    :ok
  end

  test "socket can join a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    assert {:ok, _, _channel} = Channel.join(name, "rooms:admin-lobby")
  end

  test "socket cannot join more than one channel of the same topic" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    assert {:ok, _, _channel} = Channel.join(name, "rooms:admin-lobby")
    assert {:error, {:already_started, _}} = Channel.join(name, "rooms:admin-lobby")
  end

  test "socket can join a channel and receive a reply" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    message = %{"foo" => "bar"}
    assert {:ok, ^message, _channel} = Channel.join(name, "rooms:reply", message)
  end

  test "return an error if socket is down" do
    assert {:error, :socket_not_started} = Channel.join(nil, "rooms:any")
  end

  test "socket can join a channel with params" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    user_id = "123"
    assert {:ok, _, _} = Channel.join(name, "rooms:admin-lobby", %{user: user_id})
    assert_receive %Message{event: "user:entered", payload: %{"user" => ^user_id}}
  end

  test "socket can leave a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert :ok = Channel.leave(channel)
  end

  test "client can push to a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert {:ok, %{"test" => "test"}} = Channel.push(channel, "new:msg", %{test: :test})
  end

  test "join timeouts" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:error, :timeout} = Channel.join(name, "rooms:join_timeout", %{}, 1)
  end

  test "push timeouts" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert catch_exit(Channel.push(channel, "foo:bar", %{}, 500))
  end

  test "push async" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert :ok = Channel.push_async(channel, "foo:bar", %{})
  end

  test "socket params can be sent" do
    name = :"socket_#{System.unique_integer([:positive])}"

    opts =
      @socket_config
      |> Keyword.put(:id, name)
      |> Keyword.put(:params, %{"reject" => true})
      |> Keyword.put(:caller, self())

    {:ok, _pid} = PhoenixSocketClient.start_link(opts)
    :timer.sleep(100)
    refute Socket.connected?(name)
  end

  test "socket params can be set in url" do
    name = :"socket_#{System.unique_integer([:positive])}"

    opts = [
      url: "ws://127.0.0.1:#{@port}/ws/admin/websocket?reject=true",
      serializer: Jason,
      caller: self(),
      id: name
    ]

    {:ok, _pid} = PhoenixSocketClient.start_link(opts)
    :timer.sleep(100)
    refute Socket.connected?(name)
  end

  test "pass extra headers" do
    name = :"socket_#{System.unique_integer([:positive])}"

    config =
      @socket_config
      |> Keyword.put(:id, name)
      |> Keyword.put(:headers, [{"x-extra", "value"}])

    {:ok, _pid} = PhoenixSocketClient.start_link(config)
    wait_for_socket(name)
    {:ok, headers, _channel} = Channel.join(name, "rooms:headers")
    assert %{"x-extra" => "value"} = headers
  end

  defp wait_for_socket(socket_name, retries \\ 500) do
    if retries == 0 do
      raise "Socket did not connect in time"
    end

    # Get the supervisor pid for the socket
    supervisor_pid = Process.whereis(socket_name)

    if supervisor_pid do
      # Find the socket process within the supervisor
      children = Supervisor.which_children(supervisor_pid)

      case Enum.find(children, fn {id, _, _, _} -> id == :socket end) do
        {:socket, socket_pid, _, _} ->
          try do
            case GenServer.call(socket_pid, :get_status, 1000) do
              :connected ->
                :ok

              _status ->
                :timer.sleep(100)
                wait_for_socket(socket_name, retries - 1)
            end
          catch
            :exit, _reason ->
              :timer.sleep(100)
              wait_for_socket(socket_name, retries - 1)
          end

        _ ->
          :timer.sleep(100)
          wait_for_socket(socket_name, retries - 1)
      end
    else
      case Socket.connected?(socket_name) do
        true ->
          :ok

        false ->
          :timer.sleep(100)
          wait_for_socket(socket_name, retries - 1)
      end
    end
  end

  defp start_endpoint() do
    self = self()

    capture_log(fn ->
      {:ok, pid} = Endpoint.start_link()
      send(self, {:pid, pid})
    end)

    receive do
      {:pid, pid} ->
        Process.unlink(pid)
        [endpoint: pid]
    end
  end
end
