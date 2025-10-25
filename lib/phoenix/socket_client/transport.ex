defmodule Phoenix.SocketClient.Transport do
  @moduledoc """
  Behaviour for Phoenix Socket Client transport implementations.

  Defines the interface for transport layers (WebSocket, etc.) that handle
  the underlying network connection for socket communication.
  """

  @callback open(url :: String.t(), opts :: Keyword.t()) ::
              {:ok, pid}
              | {:error, any}

  @callback close(socket :: pid) ::
              {:ok, any}
              | {:error, any}
end
