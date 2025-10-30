defmodule Phoenix.SocketClientTest.MockServer do
  @moduledoc """
  Mock Phoenix Socket Server for testing purposes.
  """

  def start do
    # Configure Phoenix
    Application.put_env(:phoenix, :json_library, Jason)

    # Find an available port
    port = find_available_port()
    Application.put_env(:phoenix_socket_client_test, :port, port)

    Task.Supervisor.start_link(name: Phoenix.SocketClientTest.TaskSupervisor)

    # Configure endpoint - will start PubSub via supervisor
    Application.put_env(
      :phoenix_socket_client_test,
      Phoenix.SocketClientTest.Endpoint,
      https: false,
      http: [ip: {127, 0, 0, 1}, port: port],
      secret_key_base: String.duplicate("abcdefgh", 8),
      debug_errors: false,
      code_reloader: false,
      server: true,
      adapter: Bandit.PhoenixAdapter,
      pubsub_server: Phoenix.SocketClientTest.PubSub,
      render_errors: [formats: [json: Phoenix.SocketClientTest.ErrorView], accepts: ~w(json)]
    )

    # Start PubSub and endpoint in a single supervisor
    {:ok, _} =
      Supervisor.start_link(
        [
          {Phoenix.PubSub, name: Phoenix.SocketClientTest.PubSub},
          Phoenix.SocketClientTest.Endpoint
        ],
        strategy: :one_for_one
      )

    # Wait for server to be ready
    wait_for_server_ready(port)

    IO.puts("Mock server started on port #{port}")
    port
  end

  def stop do
    # Find and stop the endpoint
    case Process.whereis(Phoenix.SocketClientTest.Endpoint) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :shutdown)
        :ok
    end
  end

  defp find_available_port do
    # Try to find an available port starting from 5807
    case :gen_tcp.listen(0, []) do
      {:ok, listen_socket} ->
        {:ok, port} = :inet.port(listen_socket)
        :gen_tcp.close(listen_socket)
        port

      {:error, _} ->
        # Fallback to a random port in a reasonable range
        Enum.random(5808..65_535)
    end
  end

  defp wait_for_server_ready(port, retries \\ 50) do
    if retries == 0 do
      raise "Server failed to start on port #{port}"
    end

    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        Process.sleep(50)
        wait_for_server_ready(port, retries - 1)
    end
  end
end

defmodule Phoenix.SocketClientTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :phoenix_socket_client_test

  @session_options [
    store: :cookie,
    key: "_test_key",
    signing_salt: "test_salt"
  ]

  socket("/ws/admin", Phoenix.SocketClientTest.AdminSocket, websocket: [check_origin: false])

  # Add this plug to handle basic HTTP requests
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
end

defmodule Phoenix.SocketClientTest.AdminSocket do
  use Phoenix.Socket

  channel("rooms:*", Phoenix.SocketClientTest.RoomChannel)
  channel("topic:*", Phoenix.SocketClientTest.TopicChannel)
  channel("topic:rejoin", Phoenix.SocketClientTest.TopicChannel)
  channel("topic:status", Phoenix.SocketClientTest.TopicChannel)
  channel("custom:*", Phoenix.SocketClientTest.RoomChannel)
  channel("auto:*", Phoenix.SocketClientTest.RoomChannel)
  channel("test:*", Phoenix.SocketClientTest.RoomChannel)

  def connect(params, socket, connect_info) do
    on_connect(self(), %{
      params: params,
      connect_info: connect_info
    })

    {:ok, socket}
  end

  def id(_socket), do: nil

  def on_connect(pid, info) do
    # Log info connected, increase gauge, etc.
    monitor(pid, info)
    IO.inspect({:connected, info})
  end

  def on_disconnect(info) do
    # Log info disconnected, decrease gauge, etc.
    IO.inspect({:disconnected, info})
  end

  defp monitor(pid, info) do
    Task.Supervisor.start_child(Phoenix.SocketClientTest.TaskSupervisor, fn ->
      Process.flag(:trap_exit, true)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} ->
          on_disconnect(info)
      end
    end)
  end
end

defmodule Phoenix.SocketClientTest.RoomChannel do
  use Phoenix.Channel
  require Logger

  def join("rooms:headers", _message, socket) do
    headers = socket.assigns[:headers] || %{}
    {:ok, headers, socket}
  end

  def join("rooms:join_timeout", message, socket) do
    :timer.sleep(50)
    {:ok, message, socket}
  end

  def join("rooms:reply", message, socket) do
    {:ok, message, socket}
  end

  def join("rooms:admin-lobby", message, socket) do
    if user_id = message["user"] do
      send(self(), {:after_join, user_id})
    end

    {:ok, socket}
  end

  def join("rooms:crash", _message, _socket) do
    raise "crash"
  end

  def join("custom:" <> _, message, socket) do
    {:ok, message, socket}
  end

  def join("auto:" <> _, message, socket) do
    {:ok, message, socket}
  end

  def join("test:" <> _, message, socket) do
    {:ok, message, socket}
  end

  def handle_info({:after_join, user_id}, socket) do
    push(socket, "user:entered", %{"user" => user_id})
    {:noreply, socket}
  end

  def handle_in("new:msg", message, socket) do
    broadcast!(socket, "new:msg", message)
    {:reply, {:ok, message}, socket}
  end

  def handle_in("ping", _message, socket) do
    {:reply, {:ok, %{ping: "pong"}}, socket}
  end

  def handle_in("boom", _message, _socket) do
    raise "boom"
  end

  def handle_in("foo:bar", _message, socket) do
    {:noreply, socket}
  end

  def handle_in("test_event", message, socket) do
    broadcast!(socket, "test_event", message)
    {:reply, {:ok, message}, socket}
  end
end

defmodule Phoenix.SocketClientTest.TopicChannel do
  use Phoenix.Channel

  def join("topic:fail", _message, _socket) do
    {:error, %{reason: "join failed"}}
  end

  def join("topic:crash", _message, _socket) do
    raise "crash"
  end

  def join("topic:" <> _ = topic, message, socket) do
    {:ok, %{topic: topic, message: message}, socket}
  end

  def handle_in("broadcast", message, socket) do
    broadcast!(socket, "broadcast", message)
    {:noreply, socket}
  end

  def handle_in("shout", message, socket) do
    broadcast!(socket, "shout", message)
    {:reply, {:ok, %{msg: message["body"]}}, socket}
  end
end

defmodule Phoenix.SocketClientTest.ErrorView do
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
