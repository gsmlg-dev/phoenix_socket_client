# Phoenix.SocketClient API Documentation

A comprehensive guide to using the Phoenix Socket Client library with performance optimizations.

## Table of Contents

1. [Installation](#installation)
2. [Quick Start](#quick-start)
3. [Core API](#core-api)
4. [Channel Management](#channel-management)
5. [Message Handling](#message-handling)
6. [Connection Management](#connection-management)
7. [Performance Optimizations](#performance-optimizations)
8. [Monitoring and Metrics](#monitoring-and-metrics)
9. [Error Handling](#error-handling)
10. [Advanced Configuration](#advanced-configuration)
11. [Examples](#examples)

## Installation

Add `phoenix_socket_client` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_socket_client, "~> 0.7.0"}
  ]
end
```

Then run:
```bash
mix deps.get
```

## Quick Start

### Basic Connection

```elixir
# Start a socket connection
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  auto_connect: true
])

# Join a channel
{:ok, response, channel_pid} = Phoenix.SocketClient.Channel.join(
  socket,
  "rooms:lobby",
  %{user: "alice"}
)
```

### In Supervision Tree

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Phoenix.SocketClient, [
        name: MyApp.Socket,
        url: "ws://localhost:4000/socket/websocket",
        auto_connect: true
      ]}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Core API

### Phoenix.SocketClient

The main module for socket operations.

#### start_link/1

Starts the socket client supervisor.

```elixir
@spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
```

**Options:**
- `:url` - WebSocket URL (required)
- `:auto_connect` - Auto-connect on start (default: `true`)
- `:params` - Connection parameters (default: `%{}`)
- `:headers` - Additional headers (default: `[]`)
- `:reconnect` - Auto-reconnect on disconnect (default: `true`)
- `:reconnect_interval` - Reconnect delay in ms (default: `60000`)
- `:vsn` - Phoenix protocol version (default: `"2.0.0"`)
- `:name` - Process name for registration
- `:registry_name` - Registry name for internal processes

**Example:**
```elixir
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  params: %{"token" => "your-token"},
  headers: [{"Authorization", "Bearer token"}],
  auto_connect: true
])
```

#### connect/1

Manually connect the socket.

```elixir
@spec connect(pid() | atom()) :: :ok | {:error, :no_socket_found}
```

**Example:**
```elixir
:ok = Phoenix.SocketClient.connect(socket)
```

#### disconnect/1

Disconnect the socket.

```elixir
@spec disconnect(pid() | atom()) :: :ok
```

**Example:**
```elixir
:ok = Phoenix.SocketClient.disconnect(socket)
```

#### connected?/1

Check if socket is connected.

```elixir
@spec connected?(pid() | atom()) :: boolean()
```

**Example:**
```elixir
if Phoenix.SocketClient.connected?(socket) do
  # Socket is connected
end
```

#### push/2

Send a message through the socket.

```elixir
@spec push(pid() | atom(), Phoenix.SocketClient.Message.t()) ::
  Phoenix.SocketClient.Message.t() | no_return()
```

**Example:**
```elixir
message = Phoenix.SocketClient.Message.push("rooms:lobby", "new_message", %{
  body: "Hello, world!",
  user: "alice"
})

Phoenix.SocketClient.push(socket, message)
```

#### State Management

```elixir
# Get socket state
{:ok, state} = Phoenix.SocketClient.get_state(socket)

# Get specific state value
url = Phoenix.SocketClient.get_state(socket, :url)

# Update state value
:ok = Phoenix.SocketClient.put_state(socket, :custom_data, %{key: "value"})
```

## Channel Management

### Phoenix.SocketClient.Channel

#### join/3

Join a Phoenix channel.

```elixir
@spec join(pid() | atom(), String.t(), map()) ::
  {:ok, map(), pid()} | {:error, term()}
```

**Parameters:**
- `socket` - Socket process
- `topic` - Channel topic (e.g., `"rooms:lobby"`)
- `params` - Join parameters (default: `%{}`)

**Example:**
```elixir
{:ok, response, channel_pid} = Phoenix.SocketClient.Channel.join(
  socket,
  "rooms:lobby",
  %{user_id: 123, token: "auth-token"}
)
```

#### leave/1

Leave a channel.

```elixir
@spec leave(pid()) :: :ok
```

**Example:**
```elixir
:ok = Phoenix.SocketClient.Channel.leave(channel_pid)
```

#### push/3

Send a message to a channel.

```elixir
@spec push(pid(), String.t(), any()) :: :ok
```

**Example:**
```elixir
:ok = Phoenix.SocketClient.Channel.push(
  channel_pid,
  "new_message",
  %{body: "Hello!", user: "alice"}
)
```

### Custom Channel Modules

Create custom channel behavior:

```elixir
defmodule MyApp.ChatChannel do
  use Phoenix.SocketClient.Channel

  @impl true
  def handle_join(topic, params, socket) do
    # Handle channel join
    {:ok, %{joined: true}, socket}
  end

  @impl true
  def handle_message("new_message", payload, socket) do
    # Handle incoming message
    IO.puts("Received: #{payload["body"]}")
    {:noreply, socket}
  end

  @impl true
  def handle_close(reason, socket) do
    # Handle channel close
    IO.puts("Channel closed: #{inspect(reason)}")
    socket
  end
end

# Use custom channel
{:ok, _} = Phoenix.SocketClient.Channel.join(
  socket,
  "rooms:lobby",
  %{},
  MyApp.ChatChannel
)
```

## Message Handling

### Phoenix.SocketClient.Message

#### Create Messages

```elixir
# Join message
join_msg = Phoenix.SocketClient.Message.join("rooms:lobby", %{user: "alice"})

# Leave message
leave_msg = Phoenix.SocketClient.Message.leave("rooms:lobby")

# Push message
push_msg = Phoenix.SocketClient.Message.push(
  "rooms:lobby",
  "new_message",
  %{body: "Hello, world!"}
)
```

#### Message Structure

```elixir
%Phoenix.SocketClient.Message{
  topic: "rooms:lobby",
  event: "new_message",
  payload: %{body: "Hello"},
  channel_pid: #PID<0.123.0>,
  ref: "123",
  join_ref: "123"
}
```

### Message Hooks

Register global message hooks:

```elixir
defmodule MyApp.MessageHandler do
  def handle_message(%Phoenix.SocketClient.Message{event: "new_message"} = msg, socket) do
    # Process incoming message
    IO.puts("New message: #{msg.payload["body"]}")
    socket
  end

  def handle_message(msg, socket) do
    # Handle other messages
    socket
  end
end

# Register hook (implementation depends on your setup)
Phoenix.SocketClient.register_message_hook(socket, MyApp.MessageHandler)
```

## Connection Management

### Connection States

```elixir
case Phoenix.SocketClient.get_state(socket, :status) do
  :disconnected -> # Not connected
  :connecting -> # Connection in progress
  :connected -> # Fully connected
end
```

### Reconnection Configuration

```elixir
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  reconnect: true,
  reconnect_interval: 30_000,  # 30 seconds
  max_reconnect_attempts: 10
])
```

### Connection Events

Monitor connection events:

```elixir
defmodule MyApp.ConnectionMonitor do
  use GenServer

  def start_link(socket) do
    GenServer.start_link(__MODULE__, socket)
  end

  def init(socket) do
    # Monitor connection status
    :timer.send_interval(5000, :check_connection)
    {:ok, socket}
  end

  def handle_info(:check_connection, socket) do
    case Phoenix.SocketClient.connected?(socket) do
      true -> IO.puts("Connected")
      false -> IO.puts("Disconnected")
    end
    {:noreply, socket}
  end
end
```

## Performance Optimizations

### Binary Pooling

Optimize JSON encoding/decoding for repeated patterns:

```elixir
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  binary_pool_size: 2000,        # Max patterns to cache
  binary_max_age: 600_000,       # 10 minutes TTL
  binary_cleanup_interval: 30_000 # Cleanup interval
])
```

### Route Caching

Optimize channel-to-process mapping:

```elixir
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  route_cache_size: 2000,        # Max routes to cache
  route_cache_ttl: 600_000,      # 10 minutes TTL
  route_cleanup_interval: 60_000  # Cleanup interval
])
```

### Process Hibernation

Reduce memory usage for idle connections:

```elixir
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  hibernation_enabled: true,
  hibernation_idle_timeout: 600_000,    # 10 minutes
  hibernation_memory_threshold: 50_000  # Memory threshold
])
```

### TCP Optimization

Enhanced WebSocket transport with TCP tuning:

```elixir
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  transport_opts: [
    tcp_opts: [
      nodelay: true,           # Disable Nagle's algorithm
      keepalive: true,         # Enable TCP keepalive
      buffer: 128 * 1024,      # 128KB socket buffer
      send_buffer: 64 * 1024,  # 64KB send buffer
      recv_buffer: 64 * 1024,  # 64KB receive buffer
      keepalive_idle: 7200,    # 2 hours idle time
      keepalive_interval: 75,  # 75 seconds interval
      keepalive_count: 9       # 9 keepalive probes
    ],
    connect_timeout: 10_000,    # 10 second connect timeout
    compression: true           # Enable message compression
  ]
])
```

## Monitoring and Metrics

### Performance Monitor

Access performance metrics:

```elixir
# Get current metrics
{:ok, metrics} = Phoenix.SocketClient.PerformanceMonitor.get_metrics(monitor_pid)

# Get performance summary
{:ok, summary} = Phoenix.SocketClient.PerformanceMonitor.get_summary(monitor_pid)

# Generate performance report
{:ok, report} = Phoenix.SocketClient.PerformanceMonitor.generate_report(
  monitor_pid,
  :text
)
```

### Component Statistics

Access individual component statistics:

```elixir
# Binary pool stats
{:ok, pool_stats} = Phoenix.SocketClient.BinaryPool.stats(pool_pid)

# Route cache stats
{:ok, cache_stats} = Phoenix.SocketClient.RouteCache.stats(cache_pid)

# Hibernation stats
{:ok, hibernation_stats} = Phoenix.SocketClient.HibernationManager.stats(hibernation_pid)

# Message processor stats
{:ok, processor_stats} = Phoenix.SocketClient.MessageProcessor.stats(processor_pid)
```

### Telemetry Events

Subscribe to telemetry events:

```elixir
:telemetry.attach_many("phoenix-socket-client", [
  [:phoenix_socket_client, :socket, :connected],
  [:phoenix_socket_client, :socket, :disconnected],
  [:phoenix_socket_client, :channel, :joined],
  [:phoenix_socket_client, :channel, :left],
  [:phoenix_socket_client, :message, :sent],
  [:phoenix_socket_client, :message, :received]
], &handle_telemetry/4, [])

defp handle_telemetry(event_name, measurements, metadata, config) do
  IO.inspect({event_name, measurements, metadata})
end
```

## Error Handling

### Connection Errors

```elixir
case Phoenix.SocketClient.start_link([url: "ws://invalid-host"]) do
  {:ok, socket} ->
    # Connected successfully
  {:error, reason} ->
    # Handle connection error
    IO.puts("Connection failed: #{inspect(reason)}")
end
```

### Channel Join Errors

```elixir
case Phoenix.SocketClient.Channel.join(socket, "rooms:private", %{token: "invalid"}) do
  {:ok, response, channel_pid} ->
    # Joined successfully
  {:error, :unauthorized} ->
    # Handle authorization error
  {:error, reason} ->
    # Handle other join errors
end
```

### Message Errors

```elixir
try do
  Phoenix.SocketClient.push(socket, message)
catch
    :exit, {:noproc, _} ->
      # Socket process not found
    :error, reason ->
      # Other error
end
```

### Timeout Handling

```elixir
# Add timeout to operations
Task.async(fn ->
  Phoenix.SocketClient.Channel.join(socket, "rooms:lobby", %{})
end)
|> Task.await(5000)  # 5 second timeout
```

## Advanced Configuration

### Registry Configuration

```elixir
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  registry_name: MyApp.SocketRegistry,
  name: MyApp.Socket
])
```

### Channel Module Mapping

```elixir
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  topic_channel_map: %{
    "rooms:*" => MyApp.ChatChannel,
    "users:*" => MyApp.UserChannel,
    "notifications:*" => MyApp.NotificationChannel
  },
  default_channel_module: MyApp.DefaultChannel
])
```

### JSON Library Configuration

```elixir
{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  json_library: Poison  # Use Poison instead of Jason
])
```

### Custom Transport

```elixir
defmodule MyApp.CustomTransport do
  @behaviour Phoenix.SocketClient.Transport

  def open(url, opts), do: # Custom implementation
  def close(socket), do: # Custom implementation
end

{:ok, socket} = Phoenix.SocketClient.start_link([
  url: "ws://localhost:4000/socket/websocket",
  transport: MyApp.CustomTransport
])
```

## Examples

### Real-time Chat Application

```elixir
defmodule ChatApp do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, %{})
  end

  def init(_state) do
    # Start socket connection
    {:ok, socket} = Phoenix.SocketClient.start_link([
      url: "ws://localhost:4000/socket/websocket",
      auto_connect: true
    ])

    # Join chat room
    {:ok, _response, channel} = Phoenix.SocketClient.Channel.join(
      socket,
      "rooms:general",
      %{username: "alice"}
    )

    {:ok, %{socket: socket, channel: channel}}
  end

  def send_message(pid, message) do
    GenServer.call(pid, {:send_message, message})
  end

  def handle_call({:send_message, body}, _from, state) do
    Phoenix.SocketClient.Channel.push(
      state.channel,
      "new_message",
      %{body: body, username: "alice", timestamp: DateTime.utc_now()}
    )
    {:reply, :ok, state}
  end
end

# Usage
{:ok, chat} = ChatApp.start_link()
ChatApp.send_message(chat, "Hello, everyone!")
```

### Live Data Streaming

```elixir
defmodule DataStreamer do
  use GenServer

  def start_link(symbol) do
    GenServer.start_link(__MODULE__, symbol)
  end

  def init(symbol) do
    {:ok, socket} = Phoenix.SocketClient.start_link([
      url: "ws://localhost:4000/socket/websocket",
      auto_connect: true
    ])

    {:ok, _response, channel} = Phoenix.SocketClient.Channel.join(
      socket,
      "stocks:#{symbol}",
      %{symbol: symbol}
    )

    # Start processing messages
    Process.send_after(self(), :process_messages, 1000)

    {:ok, %{socket: socket, channel: channel, data: []}}
  end

  def handle_info(:process_messages, state) do
    # Process accumulated data
    if length(state.data) > 0 do
      # Analyze or store data
      IO.puts("Received #{length(state.data)} price updates")
    end

    Process.send_after(self(), :process_messages, 5000)
    {:noreply, %{state | data: []}}
  end

  def handle_info(%Phoenix.SocketClient.Message{event: "price_update", payload: payload}, state) do
    # Accumulate price data
    new_data = [payload | state.data]
    {:noreply, %{state | data: new_data}}
  end
end
```

### Multi-socket Management

```elixir
defmodule ConnectionManager do
  use GenServer

  def start_link do
    GenServer.start_link(__MODULE__, %{})
  end

  def init(_state) do
    # Start multiple socket connections
    sockets = for env <- [:dev, :staging, :prod] do
      {:ok, socket} = Phoenix.SocketClient.start_link([
        url: get_url_for_env(env),
        registry_name: :"Registry#{env}",
        name: :"Socket#{env}"
      ])
      {env, socket}
    end

    {:ok, %{sockets: Map.new(sockets)}}
  end

  def broadcast_to_all(pid, topic, event, payload) do
    GenServer.call(pid, {:broadcast, topic, event, payload})
  end

  def handle_call({:broadcast, topic, event, payload}, _from, state) do
    for {_env, socket} <- state.sockets do
      message = Phoenix.SocketClient.Message.push(topic, event, payload)
      Phoenix.SocketClient.push(socket, message)
    end
    {:reply, :ok, state}
  end

  defp get_url_for_env(:dev), do: "ws://dev.example.com/socket/websocket"
  defp get_url_for_env(:staging), do: "ws://staging.example.com/socket/websocket"
  defp get_url_for_env(:prod), do: "ws://prod.example.com/socket/websocket"
end
```

This comprehensive API documentation provides developers with everything they need to effectively use the Phoenix Socket Client library, from basic usage to advanced performance optimizations and real-world examples.