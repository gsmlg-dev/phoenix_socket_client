defmodule PhoenixSocketClientTest.MockServer do
  @moduledoc """
  Mock Phoenix Socket Server for testing purposes.
  """

  def start do
    # Configure Phoenix
    Application.put_env(:phoenix, :json_library, Jason)

    # Configure endpoint
    Application.put_env(
      :channel_app,
      PhoenixSocketClientTest.Endpoint,
      https: false,
      http: [port: 5807],
      secret_key_base: String.duplicate("abcdefgh", 8),
      debug_errors: false,
      code_reloader: false,
      server: true,
      pubsub: [adapter: Phoenix.PubSub.PG2, name: :int_pub]
    )

    # Start the endpoint
    {:ok, _pid} = PhoenixSocketClientTest.Endpoint.start_link()
  end
end

defmodule PhoenixSocketClientTest.Endpoint do
  use Phoenix.Endpoint, otp_app: :channel_app

  socket("/ws/admin", PhoenixSocketClientTest.AdminSocket, websocket: [check_origin: false])
end

defmodule PhoenixSocketClientTest.AdminSocket do
  use Phoenix.Socket

  channel("rooms:*", PhoenixSocketClientTest.RoomChannel)
  channel("topic:*", PhoenixSocketClientTest.TopicChannel)
end

defmodule PhoenixSocketClientTest.RoomChannel do
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

  def join("rooms:admin-lobby", _message, socket) do
    {:ok, socket}
  end

  def join("rooms:crash", _message, _socket) do
    raise "crash"
  end

  def handle_in("new:msg", message, socket) do
    broadcast!(socket, "new:msg", message)
    {:reply, {:ok, %{msg: message["body"]}}, socket}
  end

  def handle_in("ping", _message, socket) do
    {:reply, {:ok, %{ping: "pong"}}, socket}
  end

  def handle_in("boom", _message, _socket) do
    raise "boom"
  end
end

defmodule PhoenixSocketClientTest.TopicChannel do
  use Phoenix.Channel

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
