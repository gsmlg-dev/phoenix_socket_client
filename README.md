# Phoenix.SocketClient

[![release](https://github.com/gsmlg-dev/phoenix_socket_client/actions/workflows/release.yml/badge.svg)](https://github.com/gsmlg-dev/phoenix_socket_client/actions/workflows/release.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_socket_client.svg)](https://hex.pm/packages/phoenix_socket_client)
[![Documentation](https://img.shields.io/badge/documentation-v0.8.9-blue)](https://hexdocs.pm/phoenix_socket_client/0.8.9)

Elixir client for Phoenix Channels WebSocket connections.

Both WebSocket transports use `HTTP.WebSocket` from `http_web_socket` 0.21.14 or later in the 0.21 series,
part of the [gsmlg-dev/http_fetch](https://github.com/gsmlg-dev/http_fetch) package family.

## Installation

Add `phoenix_socket_client` to your list of dependencies in `mix.exs`.
The package is available on [Hex.pm](https://hex.pm/packages/phoenix_socket_client).

```elixir
def deps do
  [
    {:phoenix_socket_client, "~> 0.8.9"}
  ]
end
```

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
| `:reconnect?` | `boolean()` | `true` | Enable automatic reconnection; `:reconnect` is also supported and takes precedence if both are supplied. |
| `:auto_connect` | `boolean()` | `true` | Connect automatically on startup |
| `:json_library` | `module()` | `JSON` | JSON encoder/decoder module |
| `:vsn` | `String.t()` | `"2.0.0"` | Phoenix Channels protocol version |
| `:topic_channel_map` | `map()` | `%_` | A map from a topic string to a channel module. |
| `:join_channels` | `list()` | `[]` | A list of channels to automatically join on connect. |
| `:default_channel_module` | `module()` | `Phoenix.SocketClient.Channel.EchoRoom` | The default channel module to use. |
| `:default_channel_params` | `map()` | `%_` | The default parameters to use for channels. |

### Connection Attempt Results

`Phoenix.SocketClient.connect/1` remains asynchronous and returns `:ok` when the
request is sent. Use `Phoenix.SocketClient.connection_info/1` to read the current
attempt's authoritative snapshot, independently of telemetry, sampling, or log
settings:

```elixir
Phoenix.SocketClient.connection_info(socket)
# %{attempt_ref: attempt_ref, status: :disconnected,
#   last_error: {:unexpected_status, 403}}
```

`:attempt_ref` is `nil` before the first attempt and is unique for every new
attempt, including automatic retries and socket restarts. `:status` is
`:connecting`, `:connected`, or `:disconnected`. HTTP upgrade rejections preserve
the concrete `{:unexpected_status, 401}` or `{:unexpected_status, 403}`; network
refusal and timeout retain their distinct error atoms. Structured failures
expose their category without private details. Starting a new attempt clears
the previous error, and success keeps it clear.

For authentication decisions that must inspect each result, start the client
with `auto_connect: false, reconnect?: false`, call `connect/1`, and poll
`connection_info/1` until that attempt settles. The caller then decides when to
retry. Automatic retries replace the previous snapshot. Compare `:attempt_ref`
and read the current snapshot before applying an earlier result so a stale
failure cannot supersede a newer connection. Authentication policy remains with
the application.

`disconnect/1` cancels pending automatic connection/retry timers, disables
automatic reconnection, and records `:cancelled`. Late events from an older
transport cannot change a newer attempt. A missing client returns
`{:error, :no_socket_found}` from `connection_info/1`.

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

- Elixir 1.18+
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
Telemetry metadata contains allowlisted operational fields. Message payloads,
reply bodies, transport options, arbitrary custom metadata, and exception details
are omitted; URLs omit credentials, query parameters, and fragments.

Client status and termination diagnostics omit private state, queued payloads,
current messages, and original exception arguments. Initialization, callback,
cleanup, and message-worker failures emit a fixed diagnostic and exit with
`:private_callback_failure`, preserving supervisor restart behavior. Normal exits
and explicit channel leaves retain their behavior. The underlying transport
requires `http_web_socket` 0.21.14, which protects its own diagnostics.

Supervisor startup and restart reports carry opaque references to private
configuration. A supervised client's configuration stays available until its
supervising parent exits; a directly started client's storage closes when the
client stops. Creating a child specification allocates this storage; release an
unused specification with `Phoenix.SocketClient.discard_child_spec(spec)`.

Explicit debugger access, including `:sys.get_state/1`, `:sys.log/2`, and
`:sys.trace/2`, still exposes live state or messages. Run
`MIX_ENV=test mix run scripts/privacy_crash_probe.exs` to verify the original
FunctionClauseError confidentiality regression with a synthetic sentinel.

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
