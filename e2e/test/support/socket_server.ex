defmodule PhoenixSocketClientE2E.SocketServer do
  @moduledoc false

  def start do
    Application.put_env(:phoenix, :json_library, Jason)

    port = find_available_port()

    Application.put_env(
      :phoenix_socket_client_e2e,
      PhoenixSocketClientE2E.Endpoint,
      https: false,
      http: [ip: {127, 0, 0, 1}, port: port],
      secret_key_base: String.duplicate("abcdefgh", 8),
      debug_errors: false,
      code_reloader: false,
      server: true,
      adapter: Bandit.PhoenixAdapter,
      pubsub_server: PhoenixSocketClientE2E.PubSub,
      render_errors: [formats: [json: PhoenixSocketClientE2E.ErrorView], accepts: ~w(json)]
    )

    {:ok, _pid} =
      Supervisor.start_link(
        [
          {Phoenix.PubSub, name: PhoenixSocketClientE2E.PubSub},
          PhoenixSocketClientE2E.Endpoint
        ],
        strategy: :one_for_one
      )

    wait_for_server_ready(port)
    port
  end

  defp find_available_port do
    case :gen_tcp.listen(0, []) do
      {:ok, listen_socket} ->
        {:ok, port} = :inet.port(listen_socket)
        :gen_tcp.close(listen_socket)
        port

      {:error, _reason} ->
        Enum.random(5808..65_535)
    end
  end

  defp wait_for_server_ready(port, retries \\ 50)

  defp wait_for_server_ready(port, 0) do
    raise "E2E socket server failed to start on port #{port}"
  end

  defp wait_for_server_ready(port, retries) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        Process.sleep(50)
        wait_for_server_ready(port, retries - 1)
    end
  end
end

defmodule PhoenixSocketClientE2E.Endpoint do
  use Phoenix.Endpoint, otp_app: :phoenix_socket_client_e2e

  @session_options [
    store: :cookie,
    key: "_phoenix_socket_client_e2e_key",
    signing_salt: "e2e_salt"
  ]

  socket("/ws/admin", PhoenixSocketClientE2E.AdminSocket,
    websocket: [check_origin: false, connect_info: [:x_headers]]
  )

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

defmodule PhoenixSocketClientE2E.AdminSocket do
  use Phoenix.Socket

  channel("auto:*", PhoenixSocketClientE2E.RoomChannel)
  channel("custom:*", PhoenixSocketClientE2E.RoomChannel)
  channel("rooms:*", PhoenixSocketClientE2E.RoomChannel)
  channel("test:*", PhoenixSocketClientE2E.RoomChannel)
  channel("topic:*", PhoenixSocketClientE2E.TopicChannel)

  def connect(params, socket, connect_info) do
    headers =
      connect_info
      |> Map.get(:x_headers, [])
      |> Enum.into(%{}, fn {key, value} ->
        {key |> to_string() |> String.downcase(), to_string(value)}
      end)

    socket =
      socket
      |> assign(:connect_params, params)
      |> assign(:headers, headers)

    {:ok, socket}
  end

  def id(_socket), do: nil
end

defmodule PhoenixSocketClientE2E.RoomChannel do
  use Phoenix.Channel

  def join("rooms:connect_info", message, socket) do
    {:ok,
     %{
       "headers" => socket.assigns[:headers] || %{},
       "params" => socket.assigns[:connect_params] || %{},
       "join" => message
     }, socket}
  end

  def join("rooms:join_timeout", message, socket) do
    Process.sleep(100)
    {:ok, message, socket}
  end

  def join("rooms:lobby", message, socket) do
    if user = message["user"] do
      send(self(), {:after_join, user})
    end

    {:ok, message, socket}
  end

  def join("rooms:reply", message, socket), do: {:ok, message, socket}
  def join("auto:" <> _rest, message, socket), do: {:ok, message, socket}
  def join("custom:" <> _rest, message, socket), do: {:ok, message, socket}
  def join("test:" <> _rest, message, socket), do: {:ok, message, socket}

  def handle_info({:after_join, user}, socket) do
    push(socket, "user:entered", %{"user" => user})
    {:noreply, socket}
  end

  def handle_in("new:msg", message, socket) do
    broadcast!(socket, "new:msg", message)
    {:reply, {:ok, message}, socket}
  end

  def handle_in("ping", _message, socket) do
    {:reply, {:ok, %{"ping" => "pong"}}, socket}
  end

  def handle_in("foo:bar", _message, socket) do
    {:noreply, socket}
  end

  def handle_in("test_event", message, socket) do
    broadcast!(socket, "test_event", message)
    {:reply, {:ok, message}, socket}
  end
end

defmodule PhoenixSocketClientE2E.TopicChannel do
  use Phoenix.Channel

  def join("topic:fail", _message, _socket) do
    {:error, %{reason: "join failed"}}
  end

  def join("topic:" <> _rest = topic, message, socket) do
    {:ok, %{"topic" => topic, "message" => message}, socket}
  end

  def handle_in("broadcast", message, socket) do
    broadcast!(socket, "broadcast", message)
    {:noreply, socket}
  end

  def handle_in("shout", message, socket) do
    broadcast!(socket, "shout", message)
    {:reply, {:ok, %{"msg" => message["body"]}}, socket}
  end
end

defmodule PhoenixSocketClientE2E.ErrorView do
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
