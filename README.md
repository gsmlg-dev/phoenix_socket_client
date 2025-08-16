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