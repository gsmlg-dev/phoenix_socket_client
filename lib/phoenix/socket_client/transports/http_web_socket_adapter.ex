defmodule Phoenix.SocketClient.Transports.HTTPWebSocketAdapter do
  @moduledoc false

  use GenServer

  alias HTTP.WebSocket
  alias HTTP.WebSocket.ArrayBuffer
  alias HTTP.WebSocket.Event.Close
  alias HTTP.WebSocket.Event.Error
  alias HTTP.WebSocket.Event.Message
  alias HTTP.WebSocket.Event.Open
  alias Phoenix.SocketClient.Telemetry

  @type transport_name :: :websocket | :optimized_websocket

  defstruct sender: nil,
            socket: nil,
            socket_ref: nil,
            url: nil,
            transport: :websocket,
            tcp_opts: [],
            compression_enabled: false,
            emit_connection_telemetry: false,
            closing?: false,
            connected?: false,
            last_error: nil,
            metrics: nil

  @spec start_link(String.t(), Keyword.t(), Keyword.t()) :: GenServer.on_start()
  def start_link(url, transport_opts, opts \\ []) do
    GenServer.start_link(__MODULE__, {url, transport_opts, opts})
  end

  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid) do
    GenServer.cast(pid, :close)
  catch
    :exit, _reason -> :ok
  end

  def close(_socket), do: :ok

  @spec get_stats(pid()) :: {:ok, map()} | {:error, :timeout}
  def get_stats(pid) when is_pid(pid) do
    GenServer.call(pid, :get_stats, 5_000)
  catch
    :exit, _reason -> {:error, :timeout}
  end

  def get_stats(_socket), do: {:error, :timeout}

  @impl true
  def init({url, transport_opts, opts}) do
    transport = Keyword.get(opts, :transport, :websocket)
    tcp_opts = Keyword.get(opts, :tcp_opts, Keyword.get(transport_opts, :socket_opts, []))
    emit_connection_telemetry = Keyword.get(opts, :emit_connection_telemetry, false)

    state = %__MODULE__{
      sender: Keyword.fetch!(transport_opts, :sender),
      url: url,
      transport: transport,
      tcp_opts: tcp_opts,
      compression_enabled: Keyword.get(transport_opts, :compression, false),
      emit_connection_telemetry: emit_connection_telemetry,
      metrics: new_metrics()
    }

    if emit_connection_telemetry do
      Telemetry.connection_start(%{url: url, transport: transport, tcp_opts: tcp_opts})
    end

    with {:ok, _apps} <- Application.ensure_all_started(:http_web_socket),
         %WebSocket{} = socket <-
           WebSocket.new(
             url,
             Keyword.get(transport_opts, :protocols, []),
             web_socket_options(transport_opts)
           ) do
      socket_ref = Process.monitor(socket.pid)
      {:ok, %{state | socket: socket, socket_ref: socket_ref}}
    else
      {:error, reason} ->
        emit_connection_error(state, reason)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, {:ok, state.metrics}, state}
  end

  @impl true
  def handle_cast(:close, state) do
    close_socket(state)
  end

  @impl true
  def handle_info(:close, state) do
    close_socket(state)
  end

  def handle_info({:send, message}, state) do
    send_socket_message(message, state)
  end

  def handle_info({WebSocket, socket, %Open{}}, state) do
    if same_socket?(socket, state) do
      connect_time = System.monotonic_time(:millisecond) - state.metrics.connect_started_at

      if state.emit_connection_telemetry do
        Telemetry.emit_event(
          [:phoenix, :socket_client, :transport, :connected],
          %{duration: connect_time},
          %{
            transport: state.transport,
            connect_time: connect_time,
            tcp_opts: state.tcp_opts
          }
        )

        Telemetry.connection_stop(%{
          url: state.url,
          transport: state.transport,
          transport_pid: self(),
          status: :connected
        })
      end

      send(state.sender, {:connected, self()})

      metrics = %{
        state.metrics
        | connect_time: connect_time,
          connected_at: System.monotonic_time(:millisecond),
          last_activity: System.monotonic_time(:millisecond)
      }

      {:noreply, %{state | connected?: true, metrics: metrics}}
    else
      {:noreply, state}
    end
  end

  def handle_info({WebSocket, socket, %Message{data: data}}, state) do
    if same_socket?(socket, state) do
      now = System.monotonic_time(:millisecond)

      {message_type, payload, message_size} = normalize_received_data(data)

      case message_type do
        :text -> send(state.sender, {:receive, payload})
        :binary -> send(state.sender, {:receive_binary, payload})
        :unknown -> emit_unknown_message(state, payload)
      end

      metrics = %{
        state.metrics
        | messages_received: state.metrics.messages_received + 1,
          bytes_received: state.metrics.bytes_received + message_size,
          last_activity: now
      }

      {:noreply, %{state | metrics: metrics}}
    else
      {:noreply, state}
    end
  end

  def handle_info({WebSocket, socket, %Error{reason: reason}}, state) do
    if same_socket?(socket, state) do
      Telemetry.error(%{
        transport: state.transport,
        event: :websocket_error,
        error: inspect(reason)
      })

      unless state.connected? do
        emit_connection_error(state, reason)
      end

      {:noreply, %{state | last_error: reason}}
    else
      {:noreply, state}
    end
  end

  def handle_info({WebSocket, socket, %Close{} = event}, state) do
    if same_socket?(socket, state) do
      reason = close_reason(event, state)
      emit_disconnect_metrics(reason, state)

      if state.closing? do
        send(state.sender, {:closed, :normal, self()})
      else
        send(state.sender, {:disconnected, reason, self()})
      end

      {:stop, :normal, %{state | connected?: false, socket: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{socket_ref: ref} = state) do
    unless state.closing? do
      send(state.sender, {:disconnected, reason, self()})
    end

    {:stop, :normal, %{state | connected?: false, socket: nil}}
  end

  def handle_info(message, state) do
    emit_unknown_message(state, message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{socket: %WebSocket{} = socket}) do
    _ = WebSocket.close(socket)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp web_socket_options(transport_opts) do
    [
      owner: self(),
      headers: headers(transport_opts),
      binary_type: Keyword.get(transport_opts, :binary_type, :array_buffer),
      timeout: Keyword.get(transport_opts, :timeout, 30_000),
      connect_timeout: Keyword.get(transport_opts, :connect_timeout, 30_000),
      ssl: Keyword.get(transport_opts, :ssl, Keyword.get(transport_opts, :ssl_opts, [])),
      socket_opts: Keyword.get(transport_opts, :socket_opts, []),
      max_message_size: Keyword.get(transport_opts, :max_message_size, 16 * 1024 * 1024),
      max_send_queue: Keyword.get(transport_opts, :max_send_queue, 16 * 1024 * 1024)
    ]
  end

  defp headers(transport_opts) do
    Keyword.get(transport_opts, :headers, Keyword.get(transport_opts, :extra_headers, []))
  end

  defp close_socket(%{socket: nil} = state) do
    send(state.sender, {:closed, :normal, self()})
    {:stop, :normal, %{state | connected?: false}}
  end

  defp close_socket(%{socket: socket} = state) do
    _ = WebSocket.close(socket)
    {:noreply, %{state | closing?: true}}
  end

  defp send_socket_message(_message, %{socket: nil} = state), do: {:noreply, state}

  defp send_socket_message(message, %{socket: socket} = state) do
    outbound = maybe_compress_message(message, state.compression_enabled)

    case WebSocket.send(socket, outbound) do
      :ok ->
        metrics = %{
          state.metrics
          | messages_sent: state.metrics.messages_sent + 1,
            bytes_sent: state.metrics.bytes_sent + payload_size(outbound),
            last_activity: System.monotonic_time(:millisecond)
        }

        {:noreply, %{state | metrics: metrics}}

      {:error, reason} ->
        Telemetry.error(%{
          transport: state.transport,
          event: :send_failed,
          error: inspect(reason)
        })

        {:noreply, %{state | last_error: reason}}
    end
  end

  defp maybe_compress_message(message, true)
       when is_binary(message) and byte_size(message) > 1024 do
    message
    |> :zlib.compress()
    |> WebSocket.array_buffer()
  catch
    _, _reason -> message
  end

  defp maybe_compress_message(message, _compression_enabled), do: message

  defp normalize_received_data(data) when is_binary(data), do: {:text, data, byte_size(data)}
  defp normalize_received_data(%ArrayBuffer{data: data}), do: {:binary, data, byte_size(data)}

  defp normalize_received_data(%HTTP.Blob{} = blob) do
    data = HTTP.Blob.to_binary(blob)
    {:binary, data, byte_size(data)}
  end

  defp normalize_received_data(data), do: {:unknown, data, 0}

  defp payload_size(%ArrayBuffer{byte_length: byte_length}), do: byte_length
  defp payload_size(%HTTP.Blob{} = blob), do: HTTP.Blob.size(blob)
  defp payload_size(message) when is_binary(message), do: byte_size(message)
  defp payload_size(_message), do: 0

  defp same_socket?(%WebSocket{ref: ref}, %{socket: %WebSocket{ref: ref}}), do: true
  defp same_socket?(_socket, _state), do: false

  defp close_reason(%Close{} = event, %{last_error: nil}) do
    {:closed, event.code, event.reason, event.was_clean}
  end

  defp close_reason(%Close{}, %{last_error: reason}), do: reason

  defp emit_connection_error(%{emit_connection_telemetry: true} = state, reason) do
    Telemetry.connection_error(%{
      url: state.url,
      transport: state.transport,
      error: reason
    })
  end

  defp emit_connection_error(_state, _reason), do: :ok

  defp emit_disconnect_metrics(reason, %{emit_connection_telemetry: true} = state) do
    Telemetry.emit_event(
      [:phoenix, :socket_client, :transport, :disconnected],
      %{system_time: System.system_time()},
      %{transport: state.transport, reason: reason, metrics: state.metrics}
    )

    Telemetry.emit_event(
      [:phoenix, :socket_client, :transport, :session_stats],
      session_stats(state.metrics),
      %{transport: state.transport}
    )
  end

  defp emit_disconnect_metrics(_reason, _state), do: :ok

  defp emit_unknown_message(state, message) do
    Telemetry.error(%{
      transport: state.transport,
      event: :unknown_message,
      message: message
    })
  end

  defp session_stats(metrics) do
    %{
      messages_sent: metrics.messages_sent,
      messages_received: metrics.messages_received,
      bytes_sent: metrics.bytes_sent,
      bytes_received: metrics.bytes_received,
      session_duration: session_duration(metrics)
    }
  end

  defp session_duration(%{connected_at: nil}), do: 0

  defp session_duration(%{connected_at: connected_at}) do
    System.monotonic_time(:millisecond) - connected_at
  end

  defp new_metrics do
    now = System.monotonic_time(:millisecond)

    %{
      connect_started_at: now,
      connect_time: nil,
      connected_at: nil,
      messages_sent: 0,
      messages_received: 0,
      bytes_sent: 0,
      bytes_received: 0,
      last_activity: now
    }
  end
end
