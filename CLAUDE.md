# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview
Elixir Phoenix Channels client library for establishing WebSocket connections and managing channel subscriptions.

## Development Commands
```bash
# Setup
mix deps.get          # Install dependencies
mix compile          # Compile the project

# Development workflow
mix format           # Format code
mix test             # Run all tests
mix test --cover     # Run tests with coverage
mix clean            # Clean compiled files

# Quality checks
mix format --check-formatted
mix compile --warnings-as-errors
```

## Architecture
- **Main supervisor**: `Phoenix.SocketClient` (lib/phoenix_socket_client.ex)
- **State management**: `SocketState` (Agent)
- **Connection handler**: `Socket` (GenServer)
- **Channel supervisor**: `ChannelManager` (DynamicSupervisor)
- **Channel processes**: `Channel` (GenServer)
- **Transport layer**: WebSocket via `websocket_client` library
- **Protocol support**: V1 and V2 Phoenix Channels (JSON-based)

## Key Files
- `lib/phoenix_socket_client/socket.ex` - WebSocket connection management
- `lib/phoenix_socket_client/channel.ex` - Channel process implementation
- `test/phoenix_socket_client_test.exs` - Integration tests with Phoenix server
- `mix.exs` - Dependencies and project configuration

## Testing
Integration tests use actual Phoenix server with test channels. Run `mix test` to execute full suite including WebSocket connections, channel joins/leaves, and message handling.

## Dependencies
- Runtime: `jason` (JSON), `websocket_client` (WebSocket)
- Test: `phoenix`, `plug_cowboy`/`bandit` (test servers)
- Requires Elixir 1.17+ and Erlang/OTP 26+