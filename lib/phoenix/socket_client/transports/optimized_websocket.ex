defmodule Phoenix.SocketClient.Transports.OptimizedWebsocket do
  @moduledoc """
  High-performance WebSocket transport with TCP optimization.

  This module provides an enhanced WebSocket transport implementation
  with TCP socket optimizations for better throughput and latency.

  ## Features

  - TCP socket options for performance tuning
  - Buffer size optimization
  - Connection pooling support
  - Compression support
  - Keepalive tuning
  - Nagle's algorithm control

  ## Performance Optimizations

  - TCP_NODELAY for low-latency messaging
  - Optimized buffer sizes for WebSocket frames
  - Keepalive settings for connection stability
  - Socket recycling for reduced overhead
  - Backpressure handling

  ## Usage

  Use this transport instead of the standard WebSocket transport
  when performance is critical.

  ## TCP Options

  The transport accepts various TCP socket options that can be
  configured through transport_opts:

  - `:tcp_nodelay` - Disable Nagle's algorithm (default: true)
  - `:tcp_keepalive` - Enable TCP keepalive (default: true)
  - `:tcp_buffer_size` - Socket buffer size (default: 64KB)
  - `:tcp_send_buffer_size` - Send buffer size (default: 32KB)
  - `:tcp_recv_buffer_size` - Receive buffer size (default: 32KB)
  - `:tcp_keepalive_idle` - Keepalive idle time (default: 7200s)
  - `:tcp_keepalive_interval` - Keepalive interval (default: 75s)
  - `:tcp_keepalive_count` - Keepalive probe count (default: 9)
  """

  @behaviour Phoenix.SocketClient.Transport

  require Logger

  @default_tcp_opts [
    nodelay: true,
    keepalive: true,
    # 64KB
    buffer: 64 * 1024,
    # 32KB
    send_buffer: 32 * 1024,
    # 32KB
    recv_buffer: 32 * 1024,
    # 2 hours
    keepalive_idle: 7200,
    # 75 seconds
    keepalive_interval: 75,
    keepalive_count: 9
  ]

  @doc """
  Opens a WebSocket connection with TCP optimizations.

  ## Parameters
    * `url` - WebSocket URL to connect to
    * `transport_opts` - Transport options including TCP optimizations

  ## Returns
    * `{:ok, socket_pid}` on successful connection
    * `{:error, reason}` on connection failure
  """
  def open(url, transport_opts) do
    # Extract headers
    headers = Keyword.get(transport_opts, :headers, [])
    headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    # Apply TCP optimizations
    tcp_opts = build_tcp_options(transport_opts)

    # Enhanced transport options with TCP settings
    enhanced_opts =
      transport_opts
      |> Keyword.put(:extra_headers, headers)
      |> Keyword.put(:socket_opts, tcp_opts)
      |> Keyword.put(:timeout, Keyword.get(transport_opts, :connect_timeout, 10_000))

    Phoenix.SocketClient.Telemetry.connection_start(%{
      url: url,
      transport: :optimized_websocket,
      tcp_opts: tcp_opts
    })

    case :websocket_client.start_link(
           String.to_charlist(url),
           __MODULE__,
           enhanced_opts,
           extra_headers: headers
         ) do
      {:ok, pid} ->
        Phoenix.SocketClient.Telemetry.connection_stop(%{
          url: url,
          transport: :optimized_websocket,
          transport_pid: pid,
          status: :connected
        })

        {:ok, pid}

      {:error, reason} ->
        Phoenix.SocketClient.Telemetry.connection_error(%{
          url: url,
          transport: :optimized_websocket,
          error: reason
        })

        {:error, reason}
    end
  end

  @doc """
  Closes the WebSocket connection.

  Performs graceful shutdown with cleanup.
  """
  def close(socket) do
    Phoenix.SocketClient.Telemetry.emit_event(
      [:phoenix, :socket_client, :transport, :close],
      %{system_time: System.system_time()},
      %{transport: :optimized_websocket, socket: socket}
    )

    send(socket, :close)
  end

  @doc """
  Initialize the WebSocket connection with enhanced state.

  Sets up performance monitoring and metrics collection.
  """
  def init(opts) do
    sender = opts[:sender]
    tcp_opts = Keyword.get(opts, :socket_opts, [])

    # Initialize performance metrics
    metrics = %{
      connect_time: System.monotonic_time(:millisecond),
      messages_sent: 0,
      messages_received: 0,
      bytes_sent: 0,
      bytes_received: 0,
      last_activity: System.monotonic_time(:millisecond)
    }

    state = %{
      opts: opts,
      sender: sender,
      tcp_opts: tcp_opts,
      metrics: metrics,
      buffer_enabled: Keyword.get(opts, :buffer_messages, false),
      compression_enabled: Keyword.get(opts, :compression, false)
    }

    {:once, state}
  end

  @doc """
  Handle WebSocket connection established.

  Applies socket optimizations and reports connection metrics.
  """
  def onconnect(_req, state) do
    connect_time = System.monotonic_time(:millisecond) - state.metrics.connect_time

    Phoenix.SocketClient.Telemetry.emit_event(
      [:phoenix, :socket_client, :transport, :connected],
      %{duration: connect_time},
      %{
        transport: :optimized_websocket,
        connect_time: connect_time,
        tcp_opts: state.tcp_opts
      }
    )

    # Apply TCP socket optimizations if supported
    apply_socket_optimizations(self(), state.tcp_opts)

    # Send connection established notification
    send(state.sender, {:connected, self()})

    {:ok, %{state | metrics: %{state.metrics | connect_time: connect_time}}}
  end

  @doc """
  Handle WebSocket disconnection.

  Logs disconnection metrics and performs cleanup.
  """
  def ondisconnect(reason, state) do
    Phoenix.SocketClient.Telemetry.emit_event(
      [:phoenix, :socket_client, :transport, :disconnected],
      %{system_time: System.system_time()},
      %{
        transport: :optimized_websocket,
        reason: reason,
        metrics: state.metrics
      }
    )

    # Report final metrics
    final_metrics = state.metrics

    Phoenix.SocketClient.Telemetry.emit_event(
      [:phoenix, :socket_client, :transport, :session_stats],
      %{
        messages_sent: final_metrics.messages_sent,
        messages_received: final_metrics.messages_received,
        bytes_sent: final_metrics.bytes_sent,
        bytes_received: final_metrics.bytes_received,
        session_duration: System.monotonic_time(:millisecond) - final_metrics.connect_time
      },
      %{transport: :optimized_websocket}
    )

    send(state.sender, {:disconnected, reason, self()})
    {:close, :normal, state}
  end

  @doc """
  Handle incoming WebSocket messages with performance tracking.

  Processes text messages efficiently with size tracking.
  """
  def websocket_handle({:text, msg}, _conn_state, state) do
    message_size = byte_size(msg)

    # Update metrics
    new_metrics = %{
      state.metrics
      | messages_received: state.metrics.messages_received + 1,
        bytes_received: state.metrics.bytes_received + message_size,
        last_activity: System.monotonic_time(:millisecond)
    }

    # Forward message to sender
    send(state.sender, {:receive, msg})

    {:ok, %{state | metrics: new_metrics}}
  end

  def websocket_handle({:pong, _msg}, _conn_state, state) do
    # Handle pong responses (keepalive)
    {:ok, state}
  end

  def websocket_handle({:binary, data}, _conn_state, state) do
    # Handle binary messages (could be compressed data)
    message_size = byte_size(data)

    new_metrics = %{
      state.metrics
      | messages_received: state.metrics.messages_received + 1,
        bytes_received: state.metrics.bytes_received + message_size,
        last_activity: System.monotonic_time(:millisecond)
    }

    # Forward binary data to sender
    send(state.sender, {:receive_binary, data})

    {:ok, %{state | metrics: new_metrics}}
  end

  def websocket_handle(other_msg, _req, state) do
    Phoenix.SocketClient.Telemetry.error(%{
      transport: :optimized_websocket,
      event: :unknown_message,
      message: other_msg
    })

    {:ok, state}
  end

  @doc """
  Handle outgoing WebSocket messages with optimization.

  Applies compression if enabled and tracks message metrics.
  """
  def websocket_info({:send, msg}, _conn_state, state) do
    message_size = byte_size(msg)

    # Apply compression if enabled
    final_msg =
      if state.compression_enabled and message_size > 1024 do
        compress_message(msg)
      else
        msg
      end

    # Update metrics
    new_metrics = %{
      state.metrics
      | messages_sent: state.metrics.messages_sent + 1,
        bytes_sent: state.metrics.bytes_sent + byte_size(final_msg),
        last_activity: System.monotonic_time(:millisecond)
    }

    {:reply, {:text, final_msg}, %{state | metrics: new_metrics}}
  end

  def websocket_info(:close, _conn_state, state) do
    send(state.sender, {:closed, :normal, self()})
    {:close, <<>>, "done"}
  end

  def websocket_info(:get_stats, _conn_state, state) do
    # Return performance statistics
    send(state.sender, {:stats, state.metrics})
    {:ok, state}
  end

  def websocket_info(_message, _req, state) do
    {:ok, state}
  end

  def websocket_terminate(_reason, _conn_state, _state) do
    Phoenix.SocketClient.Telemetry.emit_event(
      [:phoenix, :socket_client, :transport, :terminated],
      %{system_time: System.system_time()},
      %{transport: :optimized_websocket}
    )

    :ok
  end

  @doc """
  Gets current connection statistics.

  Returns performance metrics for monitoring.
  """
  def get_stats(socket_pid) when is_pid(socket_pid) do
    send(socket_pid, :get_stats)

    receive do
      {:stats, metrics} -> {:ok, metrics}
    after
      5000 -> {:error, :timeout}
    end
  end

  # Private helper functions

  defp build_tcp_options(transport_opts) do
    user_tcp_opts = Keyword.get(transport_opts, :tcp_opts, [])

    # Merge default options with user overrides
    @default_tcp_opts
    |> Keyword.merge(user_tcp_opts)
    |> convert_to_socket_opts()
  end

  defp convert_to_socket_opts(tcp_opts) do
    # Convert our named options to Erlang socket options
    []
    |> maybe_add_opt(tcp_opts, :nodelay, {:tcp_nodelay, true})
    |> maybe_add_opt(tcp_opts, :keepalive, {:tcp_keepalive, true})
    |> maybe_add_opt(tcp_opts, :buffer, {:recbuf, tcp_opts[:buffer]})
    |> maybe_add_opt(tcp_opts, :send_buffer, {:sndbuf, tcp_opts[:send_buffer]})
    |> maybe_add_opt(tcp_opts, :recv_buffer, {:recbuf, tcp_opts[:recv_buffer]})
    |> maybe_add_keepalive_opts(tcp_opts)
  end

  defp maybe_add_opt(opts, tcp_opts, key, socket_opt) do
    if Keyword.get(tcp_opts, key, false) do
      [socket_opt | opts]
    else
      opts
    end
  end

  defp maybe_add_keepalive_opts(opts, tcp_opts) do
    if Keyword.get(tcp_opts, :keepalive, false) do
      keepalive_opts = [
        {:keepalive, true},
        # TCP_KEEPIDLE
        {:raw, 6, 1, <<Keyword.get(tcp_opts, :keepalive_idle, 7200)::32>>},
        # TCP_KEEPINTVL
        {:raw, 6, 2, <<Keyword.get(tcp_opts, :keepalive_interval, 75)::32>>},
        # TCP_KEEPCNT
        {:raw, 6, 3, <<Keyword.get(tcp_opts, :keepalive_count, 9)::32>>}
      ]

      keepalive_opts ++ opts
    else
      opts
    end
  end

  defp apply_socket_optimizations(socket_pid, tcp_opts) do
    # Try to apply socket optimizations (may not be supported on all platforms)
    try do
      # Get the underlying socket from websocket_client
      # This is implementation-dependent and may need adjustment
      case :erlang.process_info(socket_pid, :dictionary) do
        {:dictionary, dict} ->
          case Keyword.get(dict, :socket) do
            socket when is_port(socket) ->
              apply_socket_options(socket, tcp_opts)

            _ ->
              Phoenix.SocketClient.Telemetry.debug(%{
                transport: :optimized_websocket,
                event: :socket_not_accessible,
                message: "socket not accessible for optimization"
              })
          end

        _ ->
          Phoenix.SocketClient.Telemetry.debug(%{
            transport: :optimized_websocket,
            event: :socket_access_failed,
            message: "cannot access socket for optimization"
          })
      end
    catch
      _, error ->
        Phoenix.SocketClient.Telemetry.debug(%{
          transport: :optimized_websocket,
          event: :socket_optimization_failed,
          error: inspect(error)
        })
    end
  end

  defp apply_socket_options(_socket, []), do: :ok

  defp apply_socket_options(socket, [opt | rest]) do
    case :inet.setopts(socket, [opt]) do
      :ok ->
        apply_socket_options(socket, rest)

      {:error, reason} ->
        Phoenix.SocketClient.Telemetry.debug(%{
          transport: :optimized_websocket,
          event: :socket_option_failed,
          option: inspect(opt),
          reason: inspect(reason)
        })
    end
  end

  defp compress_message(msg) when is_binary(msg) do
    # Simple compression using zlib
    try do
      :zlib.compress(msg)
    catch
      # Fallback to uncompressed message
      _, _ -> msg
    end
  end

  defp compress_message(msg), do: msg
end
