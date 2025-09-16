defmodule Phoenix.SocketClient.State do
  @moduledoc """
  Represents the state of a Phoenix Socket Client connection.
  """

  defstruct [
    :url,
    :json_library,
    :params,
    :vsn,
    :auto_connect,
    :reconnect,
    :reconnect_interval,
    :reconnect_timer,
    :status,
    :serializer,
    :transport,
    :transport_opts,
    :transport_pid,
    :to_send_r,
    :ref,
    :sup_pid,
    :headers,
    custom: %{}
  ]
end
