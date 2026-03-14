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
mix lint                         # credo --strict + dialyzer
```

## Architecture

Supervision tree per socket instance:
```
Phoenix.SocketClient (API wrapper, starts Supervisor)
└── Phoenix.SocketClient.Supervisor
    ├── Phoenix.SocketClient.Agent (process-scoped state storage)
    ├── Phoenix.SocketClient.Socket (GenServer - WebSocket connection lifecycle)
    └── Phoenix.SocketClient.ChannelManager (DynamicSupervisor)
        └── Phoenix.SocketClient.Channel (GenServer per joined channel)
```

- **Transport**: WebSocket via `websocket_client` library
- **Protocol**: V1 ("1.0.0", deprecated) and V2 ("2.0.0") — message encoding in `Message.V1`/`Message.V2`
- **Message delivery**: Channel broadcasts are sent as `%Phoenix.SocketClient.Message{}` to the caller process, or handled via registered hooks
- **Custom channels**: `use Phoenix.SocketClient.Channel` and map topics via `:topic_channel_map` option
- **Telemetry**: Events under `[:phoenix_socket_client, :socket | :channel | :message | :state]`

## Testing
Integration tests start a real Phoenix server (bandit) on a dynamic port (`test/support/`). Test support modules are compiled only in `:test` env via `elixirc_paths`.

V1 protocol is deprecated — tests default to V2.

## Dependencies
- Runtime: `jason`, `websocket_client`, `telemetry`
- Dev: `credo`, `dialyxir`, `ex_doc`, `benchee`
- Test: `phoenix`, `phoenix_pubsub`, `bandit`
- Requires Elixir 1.17+ and Erlang/OTP 26+