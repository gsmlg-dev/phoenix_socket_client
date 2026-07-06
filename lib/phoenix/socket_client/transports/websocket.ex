defmodule Phoenix.SocketClient.Transports.Websocket do
  @moduledoc """
  WebSocket transport implementation using the http_web_socket library.

  Provides WebSocket connectivity for Phoenix Socket Client using the
  `HTTP.WebSocket` API as the underlying transport mechanism.
  """

  @behaviour Phoenix.SocketClient.Transport

  alias Phoenix.SocketClient.Transports.HTTPWebSocketAdapter

  def open(url, transport_opts) do
    HTTPWebSocketAdapter.start_link(url, transport_opts, transport: :websocket)
  end

  def close(socket) do
    HTTPWebSocketAdapter.close(socket)
  end
end
