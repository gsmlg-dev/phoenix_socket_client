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
mix test test/file/name_test.exs:line  # Run specific test
mix test path/to/file_test.exs          # Run specific test file
mix clean            # Clean compiled files

# Quality checks
mix format --check-formatted
mix compile --warnings-as-errors
```

## Architecture
- **Main supervisor**: `Phoenix.SocketClient` (lib/phoenix_socket_client.ex) - API wrapper
- **Root supervisor**: `Phoenix.SocketClient.Supervisor` - Manages all child processes
- **State management**: `Phoenix.SocketClient.Agent` - Process-scoped state storage
- **Connection handler**: `Phoenix.SocketClient.Socket` (GenServer) - WebSocket connection lifecycle
- **Channel supervisor**: `ChannelManager` (DynamicSupervisor) - Manages channel processes
- **Channel processes**: `Channel` (GenServer) - Individual channel message handling
- **Transport layer**: WebSocket via `websocket_client` library (V1 and V2 protocol support)
- **Message handling**: Protocol-specific modules in `Phoenix.SocketClient.Message.V1/V2`
- **Telemetry**: Built-in events for monitoring socket/channel lifecycle and message flow

## Key Files
- `lib/phoenix_socket_client/socket.ex` - WebSocket connection management and lifecycle
- `lib/phoenix_socket_client/channel.ex` - Channel process implementation and messaging
- `lib/phoenix_socket_client/agent.ex` - Process-scoped state storage
- `lib/phoenix_socket_client/supervisor.ex` - Root supervisor tree structure
- `lib/phoenix_socket_client/telemetry.ex` - Telemetry event definitions
- `lib/phoenix_socket_client/message/v1.ex` and `v2.ex` - Protocol-specific message encoding
- `test/phoenix_socket_client_test.exs` - Full integration tests with mock Phoenix server
- `test/test_helper.exs` - Test setup with mock server on dynamic port

## Testing
Integration tests use a mock Phoenix server that starts on a dynamic port. The test suite covers WebSocket connections, channel joins/leaves, message handling, and error scenarios. Tests require actual Phoenix server dependencies (phoenix, phoenix_pubsub, bandit) for comprehensive integration testing.

Note: V1 Phoenix Channels protocol ("1.0.0") is deprecated - tests use V2 protocol by default.

## Development Notes
- Supports Phoenix Channels protocol V1 (deprecated) and V2
- Uses Agent for process-scoped state management
- Custom channel modules can be created with `use Phoenix.SocketClient.Channel`
- Message handling via process messages or registered hooks
- Comprehensive telemetry coverage for monitoring and debugging

## Dependencies
- Runtime: `jason` (JSON), `websocket_client` (WebSocket), `telemetry`
- Test: `phoenix`, `phoenix_pubsub`, `bandit` (test servers)
- Requires Elixir 1.17+ and Erlang/OTP 26+