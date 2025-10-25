defmodule Phoenix.SocketClient.Channel.State do
  @moduledoc """
  State structure for Phoenix Socket Client channel processes.

  Maintains the state of individual channel connections including
  topic, params, pending pushes, and registered hooks.
  """

  @type t :: %__MODULE__{
          caller: pid() | nil,
          sup_pid: pid(),
          socket_pid: pid(),
          topic: String.t(),
          params: map(),
          pushes: list(),
          join_ref: String.t() | nil,
          hooks: map(),
          registry_name: atom()
        }

  defstruct caller: nil,
            sup_pid: nil,
            socket_pid: nil,
            topic: nil,
            params: %{},
            pushes: [],
            join_ref: nil,
            hooks: %{},
            registry_name: nil,
            join_start_time: nil,
            leave_start_time: nil
end
