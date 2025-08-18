# PhoenixSocketClient

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
{:ok, socket} = PhoenixSocketClient.start_link(
  url: "ws://localhost:4000/socket/websocket",
  params: %{"token" => "your-token"},
  headers: [{"Authorization", "Bearer your-token"}]
)
```

### Joining Channels

```elixir
{:ok, response, channel} = PhoenixSocketClient.Channel.join(socket, "rooms:lobby", %{user_id: 123})

# Handle incoming messages
PhoenixSocketClient.Channel.on(channel, "new_msg", fn payload ->
  IO.inspect(payload)
end)

# Push messages to the channel
PhoenixSocketClient.Channel.push(channel, "new_msg", %{"body" => "Hello"})
```

### Configuration Options

- `:url` - WebSocket URL (required)
- `:params` - Query parameters for connection
- `:headers` - HTTP headers for connection
- `:transport` - Transport module (default: `PhoenixSocketClient.Transports.WebSocket`)
- `:heartbeat_interval` - Keep-alive interval in ms (default: 30_000)
- `:reconnect_interval` - Reconnection delay in ms (default: 60_000)
- `:reconnect?` - Enable auto-reconnect (default: true)

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
PhoenixSocketClient.Telemetry.attach_debug_handler()
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