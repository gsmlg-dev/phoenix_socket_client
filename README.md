# Phoenix.SocketClient

[![release](https://github.com/gsmlg-dev/phoenix_socket_client/actions/workflows/release.yml/badge.svg)](https://github.com/gsmlg-dev/phoenix_socket_client/actions/workflows/release.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_socket_client.svg)](https://hex.pm/packages/phoenix_socket_client)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/phoenix_socket_client)


Elixir client for Phoenix Channels WebSocket connections.

## Installation

Add `phoenix_socket_client` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_socket_client, "~> 0.1.0"}
  ]
end
```

## Usage

### Basic Connection

```elixir
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
  def init({sup_pid, socket_pid, topic, params}) do
    # initialize your channel state
    {:ok, %{sup_pid: sup_pid, socket_pid: socket_pid, topic: topic, params: params}}
  end

  # optional callbacks
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

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
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

### Connection Recovery

```elixir
# Monitor connection status
Phoenix.SocketClient.Telemetry.attach_debug_handler()

# Implement custom reconnection logic
:telemetry.attach(
  "reconnection-handler",
  [:phoenix_socket_client, :socket, :disconnected],
  fn _event, _measurements, _metadata, _config ->
    Process.sleep(1000)
    Phoenix.SocketClient.connect(socket)
  end,
  %{}
)
```

## Development

### Setup

```bash
# Install dependencies
mix deps.get

# Compile
mix compile

# Run tests
mix test

# Format code
mix format
```

### Requirements

- Elixir 1.17+
- Erlang/OTP 26+

## Architecture

The client uses a supervisor tree with separate processes for:
- Socket connection management
- Channel lifecycle
- Individual channel processes
- State management

All processes are properly supervised with automatic restart strategies.

## Telemetry

The library includes comprehensive telemetry events for monitoring and debugging:

### Socket Events
- `[:phoenix_socket_client, :socket, :connecting]` - Connection attempt started
- `[:phoenix_socket_client, :socket, :connected]` - Connection established
- `[:phoenix_socket_client, :socket, :disconnected]` - Connection lost
- `[:phoenix_socket_client, :socket, :connection_error]` - Connection failed
- `[:phoenix_socket_client, :socket, :reconnecting]` - Reconnection attempt
- `[:phoenix_socket_client, :socket, :heartbeat]` - Heartbeat sent

### Channel Events
- `[:phoenix_socket_client, :channel, :joined]` - Successfully joined channel
- `[:phoenix_socket_client, :channel, :join_error]` - Failed to join channel
- `[:phoenix_socket_client, :channel, :left]` - Left channel

### Message Events
- `[:phoenix_socket_client, :message, :sent]` - Message sent to server
- `[:phoenix_socket_client, :message, :received]` - Message received from server

### Example Usage

```elixir
# Attach a telemetry handler
:telemetry.attach_many(
  "my-handler",
  [
    [:phoenix_socket_client, :socket, :connected],
    [:phoenix_socket_client, :socket, :disconnected],
    [:phoenix_socket_client, :channel, :joined]
  ],
  fn event_name, measurements, metadata, _config ->
    IO.inspect({event_name, metadata})
  end,
  %{}
)

# Use built-in debug handler
Phoenix.SocketClient.Telemetry.attach_debug_handler()
```

### Dependencies

Add `:telemetry` to your dependencies if using custom handlers:

```elixir
def deps do
  [
    {:telemetry, "~> 1.0"}
  ]
end
```

### Deprecation Notices

- **V1 Protocol Deprecation**: Phoenix Channels V1 protocol ("1.0.0") is deprecated and will be removed in a future version. Use V2 protocol ("2.0.0") for new applications.
- **Migration**: Update your `:vsn` configuration from `"1.0.0"` to `"2.0.0"` to avoid deprecation warnings.