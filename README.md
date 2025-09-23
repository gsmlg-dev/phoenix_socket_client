# Phoenix.SocketClient

[![release](https://github.com/gsmlg-dev/phoenix_socket_client/actions/workflows/release.yml/badge.svg)](https://github.com/gsmlg-dev/phoenix_socket_client/actions/workflows/release.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_socket_client.svg)](https://hex.pm/packages/phoenix_socket_client)
[![Documentation](https://img.shields.io/badge/documentation-blue)](https://hexdocs.pm/phoenix_socket_client)

Elixir client for Phoenix Channels WebSocket connections.

## Installation

Add `phoenix_socket_client` to your list of dependencies in `mix.exs`.
The package is available on [Hex.pm](https://hex.pm/packages/phoenix_socket_client).

```elixir
def deps do
  [
    {:phoenix_socket_client, "~> 0.7.0"}
  ]
end
```

## Documentation

Full documentation is available in the `docs` directory.

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

The library includes comprehensive telemetry events for monitoring and debugging.
The events are structured as follows:

- `[:phoenix_socket_client, :socket]` - Events related to the socket lifecycle.
- `[:phoenix_socket_client, :channel]` - Events related to channel lifecycle.
- `[:phoenix_socket_client, :message]` - Events related to messages.
- `[:phoenix_socket_client, :state]` - Events related to state changes.

The `action` key in the metadata distinguishes the specific event.
For example, a socket connection event is emitted as `[:phoenix_socket_client, :socket]`
with metadata `%{action: :connected, ...}`.

### Example Usage

```elixir
# Attach a telemetry handler
:telemetry.attach(
  "my-handler",
  [:phoenix_socket_client, :socket],
  fn _event_name, _measurements, metadata, _config ->
    if metadata.action == :connected do
      IO.puts("Socket connected!")
    end
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
