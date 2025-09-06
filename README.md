# PhoenixSocketClient

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
{:ok, socket} = PhoenixSocketClient.start_link(
  url: "ws://localhost:4000/socket/websocket",
  params: %{"token" => "your-token"},
  headers: [{"Authorization", "Bearer your-token"}]
)
```

### Joining Channels

```elixir
{:ok, response, channel} = PhoenixSocketClient.Channel.join(socket, "rooms:lobby", %{user_id: 123})

# Handle incoming messages via message passing
# Messages are received as PhoenixSocketClient.Message structs
receive do
  %PhoenixSocketClient.Message{event: "new_msg", payload: payload} ->
    IO.inspect(payload)
  %PhoenixSocketClient.Message{event: "user:joined", payload: payload} ->
    IO.puts("User joined: #{inspect(payload)}")
end

# Or in tests/explicit handling:
assert_receive %PhoenixSocketClient.Message{event: "new_msg", payload: %{"body" => body}}

# Push messages to the channel
PhoenixSocketClient.Channel.push(channel, "new_msg", %{"body" => "Hello"})
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:url` | `String.t()` | **Required** | WebSocket URL (e.g., "ws://localhost:4000/socket/websocket") |
| `:params` | `map() \| keyword()` | `%{}` | Query parameters for connection |
| `:headers` | `[{String.t(), String.t()}]` | `[]` | HTTP headers for connection |
| `:transport` | `module()` | `PhoenixSocketClient.Transports.Websocket` | Transport module |
| `:heartbeat_interval` | `integer()` | `30_000` | Keep-alive interval in milliseconds |
| `:reconnect_interval` | `integer()` | `60_000` | Reconnection delay in milliseconds |
| `:reconnect?` | `boolean()` | `true` | Enable automatic reconnection |
| `:auto_connect` | `boolean()` | `true` | Connect automatically on startup |
| `:serializer` | `module()` | `Jason` | JSON serializer module |
| `:vsn` | `String.t()` | `"2.0.0"` | Phoenix Channels protocol version (V1 is deprecated) |

### Message Handling Examples

```elixir
# Using in a GenServer or other process
{:ok, response, channel} = PhoenixSocketClient.Channel.join(socket, "rooms:lobby")

# In your GenServer handle_info or process loop:
def handle_info(%PhoenixSocketClient.Message{event: "new_msg", payload: payload}, state) do
  IO.puts("New message: #{inspect(payload)}")
  {:noreply, state}
end

def handle_info(%PhoenixSocketClient.Message{event: "user:joined", payload: %{"user" => user}}, state) do
  IO.puts("User #{user} joined the room")
  {:noreply, state}
end

# For simple usage, use receive blocks:
receive do
  %PhoenixSocketClient.Message{event: event, payload: payload} ->
    IO.puts("Received event: #{event} with payload: #{inspect(payload)}")
after
  5_000 -> IO.puts("No messages received")
end
```

### Error Handling Examples

```elixir
# Handle connection errors
{:ok, socket} = PhoenixSocketClient.start_link(
  url: "ws://localhost:4000/socket/websocket",
  params: %{"token" => "invalid-token"}
)

# Check connection status
if PhoenixSocketClient.Socket.connected?(socket) do
  {:ok, _response, channel} = PhoenixSocketClient.Channel.join(socket, "rooms:lobby")
else
  IO.puts("Failed to connect to server")
end

# Handle channel join errors
case PhoenixSocketClient.Channel.join(socket, "rooms:private", %{user_id: 123}) do
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
case PhoenixSocketClient.Channel.push(channel, "new_msg", %{body: "Hello"}, 5000) do
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
PhoenixSocketClient.Telemetry.attach_debug_handler()

# Implement custom reconnection logic
:telemetry.attach(
  "reconnection-handler",
  [:phoenix_socket_client, :socket, :disconnected],
  fn _event, _measurements, _metadata, _config ->
    Process.sleep(1000)
    PhoenixSocketClient.connect(socket)
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

### Deprecation Notices

- **V1 Protocol Deprecation**: Phoenix Channels V1 protocol ("1.0.0") is deprecated and will be removed in a future version. Use V2 protocol ("2.0.0") for new applications.
- **Migration**: Update your `:vsn` configuration from `"1.0.0"` to `"2.0.0"` to avoid deprecation warnings.