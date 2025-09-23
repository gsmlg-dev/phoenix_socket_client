# Documentation

## Usage

### Basic Connection

The socket can be started as a supervised process by adding it to your supervision tree.
You can also start it as a standalone process.

```elixir
# As a supervised process
def start(_type, _args) do
  children = [
    {Phoenix.SocketClient, url: "ws://localhost:4000/socket/websocket", name: MyApp.Socket}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end

# As a standalone process
{:ok, socket} = Phoenix.SocketClient.start_link(
  url: "ws://localhost:4000/socket/websocket",
  params: %{"token" => "your-token"},
  headers: [{"Authorization", "Bearer your-token"}]
)
```

### Joining Channels

```elixir
{:ok, response, channel} = Phoenix.SocketClient.Channel.join(socket, "rooms:lobby", %{user_id: 123})

# Handle incoming messages via message passing
# Messages are received as Phoenix.SocketClient.Message structs
receive do
  %Phoenix.SocketClient.Message{event: "new_msg", payload: payload} ->
    IO.inspect(payload)
  %Phoenix.SocketClient.Message{event: "user:joined", payload: payload} ->
    IO.puts("User joined: #{inspect(payload)}")
end

# Or in tests/explicit handling:
assert_receive %Phoenix.SocketClient.Message{event: "new_msg", payload: %{"body" => body}}

# Push messages to the channel
Phoenix.SocketClient.Channel.push(channel, "new_msg", %{"body" => "Hello"})
```

### Custom Channels

You can create your own channel modules to handle channel logic in a more structured way.
The easiest way to create a custom channel is to `use Phoenix.SocketClient.Channel`:

```elixir
defmodule MyChannel do
  use Phoenix.SocketClient.Channel

  @impl true
  def init(args) do
    # initialize your channel state
    # args: {sup_pid, socket_pid, topic, params}
    {:ok, args}
  end

  # optional callbacks
  # @impl true
  # def handle_in(event, payload, state) do
  #   {:noreply, state}
  # end
end
```

Then, you can use the `topic_channel_map` option when starting the socket to map a topic to your custom channel:

```elixir
{:ok, socket} = Phoenix.SocketClient.start_link(
  url: "ws://localhost:4000/socket/websocket",
  topic_channel_map: %{
    "rooms:lobby" => MyChannel
  }
)
```

### Handling Incoming Messages with Hooks

You can also handle incoming messages using hooks. This is useful when you want to handle messages in a more direct way, without using message passing.

```elixir
{:ok, response, channel} = Phoenix.SocketClient.Channel.join(socket, "rooms:lobby")

# Register a hook for the "new_msg" event
Phoenix.SocketClient.Channel.on(channel, "new_msg", fn payload ->
  IO.inspect(payload)
end)

# Unregister the hook
Phoenix.SocketClient.Channel.off(channel, "new_msg")
```

You can also use a module as a hook. The module must implement a `handle_in/2` function, which will be called with the event and the payload.

```elixir
defmodule MyHook do
  def handle_in(event, payload) do
    IO.puts("Got event \#{event} with payload \#{inspect payload}")
  end
end

{:ok, response, channel} = Phoenix.SocketClient.Channel.join(socket, "rooms:lobby")

# Register a module hook for the "new_msg" event
Phoenix.SocketClient.Channel.on(channel, "new_msg", MyHook)
```

### Reconfiguring the Socket

You can reconfigure the socket client at runtime using the `reconfigure/2` function.
If any connection-related options are changed, the socket will be restarted.

```elixir
# Change the url
Phoenix.SocketClient.reconfigure(socket, url: "ws://new.example.com/socket")

# Change the connection params
Phoenix.SocketClient.reconfigure(socket, params: %{"token" => "new-token"})
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:name` | `atom()` | `nil` | The name to register the socket supervisor. |
| `:url` | `String.t()` | **Required** | WebSocket URL (e.g., "ws://localhost:4000/socket/websocket") |
| `:params` | `map() \| keyword()` | `%{}` | Query parameters for connection |
| `:headers` | `[{String.t(), String.t()}]` | `[]` | HTTP headers for connection |
| `:transport` | `module()` | `Phoenix.SocketClient.Transports.Websocket` | Transport module |
| `:heartbeat_interval` | `integer()` | `30_000` | Keep-alive interval in milliseconds |
| `:reconnect_interval` | `integer()` | `60_000` | Reconnection delay in milliseconds |
| `:reconnect?` | `boolean()` | `true` | Enable automatic reconnection |
| `:auto_connect` | `boolean()` | `true` | Connect automatically on startup |
| `:serializer` | `module()` | `Jason` | JSON serializer module |
| `:vsn` | `String.t()` | `"2.0.0"` | Phoenix Channels protocol version (V1 is deprecated) |
| `:topic_channel_map` | `map()` | `%_` | A map from a topic string to a channel module. |

### Message Handling Examples

```elixir
# Using in a GenServer or other process
{:ok, response, channel} = Phoenix.SocketClient.Channel.join(socket, "rooms:lobby")

# In your GenServer handle_info or process loop:
def handle_info(%Phoenix.SocketClient.Message{event: "new_msg", payload: payload}, state) do
  IO.puts("New message: #{inspect(payload)}")
  {:noreply, state}
end

def handle_info(%Phoenix.SocketClient.Message{event: "user:joined", payload: %{"user" => user}}, state) do
  IO.puts("User #{user} joined the room")
  {:noreply, state}
end

# For simple usage, use receive blocks:
receive do
  %Phoenix.SocketClient.Message{event: event, payload: payload} ->
    IO.puts("Received event: #{event} with payload: #{inspect(payload)}")
after
  5_000 -> IO.puts("No messages received")
end
```

### Error Handling Examples

```elixir
# Handle connection errors
{:ok, socket} = Phoenix.SocketClient.start_link(
  url: "ws://localhost:4000/socket/websocket",
  params: %{"token" => "invalid-token"}
)

# Check connection status
if Phoenix.SocketClient.connected?(socket) do
  {:ok, _response, channel} = Phoenix.SocketClient.Channel.join(socket, "rooms:lobby")
else
  IO.puts("Failed to connect to server")
end

# Handle channel join errors
case Phoenix.SocketClient.Channel.join(socket, "rooms:private", %{user_id: 123}) do
  {:ok, response, channel} ->
    # Successfully joined channel
    IO.inspect(response)

  {:error, :timeout} ->
    # Join request timed out
    IO.puts("Channel join timed out")

  {:error, :unauthorized} ->
    # Not authorized to join this channel
    IO.puts("Not authorized to join channel")

  {:error, reason} ->
    # Other join errors
    IO.puts("Failed to join channel: #{inspect(reason)}")
end

# Handle message push errors
case Phoenix.SocketClient.Channel.push(channel, "new_msg", %{body: "Hello"}, 5000) do
  {:ok, response} ->
    # Message sent successfully
    IO.inspect(response)

  {:error, :timeout} ->
    # Push request timed out
    IO.puts("Message push timed out")

  {:error, :channel_closed} ->
    # Channel was closed
    IO.puts("Channel is no longer available")
end
```
