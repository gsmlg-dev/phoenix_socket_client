defmodule Phoenix.SocketClient.Transports.OptimizedWebsocket do
  @moduledoc """
  WebSocket transport using `HTTP.WebSocket` with TCP socket options.

  This transport preserves the public options from the previous optimized
  transport while using `:http_web_socket` as the underlying WebSocket client.
  """

  @behaviour Phoenix.SocketClient.Transport

  alias Phoenix.SocketClient.Transports.HTTPWebSocketAdapter

  @default_tcp_opts [
    nodelay: true,
    keepalive: true,
    # 64KB
    buffer: 64 * 1024,
    # 32KB
    send_buffer: 32 * 1024,
    # 32KB
    recv_buffer: 32 * 1024,
    # Kept for option compatibility. Portable socket options only apply
    # nodelay/keepalive/buffer sizes during connect.
    keepalive_idle: 7200,
    keepalive_interval: 75,
    keepalive_count: 9
  ]

  @doc """
  Opens a WebSocket connection with TCP options.
  """
  def open(url, transport_opts) do
    tcp_opts = build_tcp_options(transport_opts)
    socket_opts = tcp_opts ++ Keyword.get(transport_opts, :socket_opts, [])

    enhanced_opts =
      transport_opts
      |> Keyword.put(:socket_opts, socket_opts)
      |> Keyword.put_new(:connect_timeout, Keyword.get(transport_opts, :connect_timeout, 10_000))

    HTTPWebSocketAdapter.start_link(url, enhanced_opts,
      transport: :optimized_websocket,
      tcp_opts: tcp_opts,
      emit_connection_telemetry: true
    )
  end

  @doc """
  Closes the WebSocket connection.
  """
  def close(socket) do
    Phoenix.SocketClient.Telemetry.emit_event(
      [:phoenix, :socket_client, :transport, :close],
      %{system_time: System.system_time()},
      %{transport: :optimized_websocket, socket: socket}
    )

    HTTPWebSocketAdapter.close(socket)
  end

  @doc """
  Gets current connection statistics.
  """
  def get_stats(socket_pid) when is_pid(socket_pid) do
    HTTPWebSocketAdapter.get_stats(socket_pid)
  end

  def get_stats(_socket_pid), do: {:error, :timeout}

  defp build_tcp_options(transport_opts) do
    transport_opts
    |> Keyword.get(:tcp_opts, [])
    |> then(&Keyword.merge(@default_tcp_opts, &1))
    |> convert_to_socket_opts()
  end

  defp convert_to_socket_opts(tcp_opts) do
    []
    |> maybe_add_boolean_opt(tcp_opts, :nodelay, :nodelay)
    |> maybe_add_boolean_opt(tcp_opts, :keepalive, :keepalive)
    |> maybe_add_integer_opt(tcp_opts, :buffer, :buffer)
    |> maybe_add_integer_opt(tcp_opts, :send_buffer, :sndbuf)
    |> maybe_add_integer_opt(tcp_opts, :recv_buffer, :recbuf)
    |> Enum.reverse()
  end

  defp maybe_add_boolean_opt(opts, tcp_opts, key, socket_key) do
    if Keyword.get(tcp_opts, key, false) do
      [{socket_key, true} | opts]
    else
      opts
    end
  end

  defp maybe_add_integer_opt(opts, tcp_opts, key, socket_key) do
    case Keyword.get(tcp_opts, key) do
      value when is_integer(value) and value > 0 -> [{socket_key, value} | opts]
      _value -> opts
    end
  end
end
