defmodule Phoenix.SocketClient.State do
  @moduledoc """
  Represents the state of a Phoenix Socket Client connection.
  """

  @typedoc """
  The state struct for the socket client.
  """
  @type t :: %__MODULE__{
          url: String.t(),
          json_library: module(),
          params: map(),
          vsn: String.t(),
          auto_connect: boolean(),
          reconnect: boolean(),
          reconnect_interval: non_neg_integer(),
          reconnect_timer: reference() | nil,
          status: :disconnected | :connecting | :connected,
          serializer: module(),
          transport: module(),
          transport_opts: keyword(),
          transport_pid: pid() | nil,
          to_send_r: list(Phoenix.SocketClient.Message.t()),
          ref: integer(),
          sup_pid: pid() | nil,
          headers: list({String.t(), String.t()}),
          custom: map()
        }

  @derive {Jason.Encoder,
           only: [
             :url,
             :params,
             :vsn,
             :auto_connect,
             :reconnect,
             :reconnect_interval,
             :status,
             :custom
           ]}
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
