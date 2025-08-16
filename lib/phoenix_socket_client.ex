defmodule PhoenixSocketClient do
  @moduledoc """
  A Supervisor for starting, supervising, and managing socket connections.
  """
  use Supervisor

  alias PhoenixSocketClient.Socket

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    server_pid = self()

    children = [
      {PhoenixSocketClient.SocketState, {server_pid, opts}}
      |> Supervisor.child_spec(id: :socket_state),
      {PhoenixSocketClient.Socket, {server_pid, opts}}
      |> Supervisor.child_spec(id: :socket),
      {PhoenixSocketClient.ChannelManager, {server_pid, opts}}
      |> Supervisor.child_spec(id: :channel_manager)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def get_process_pid(supervisor, name) do
    try do
      case Process.alive?(supervisor) do
        false ->
          nil

        true ->
          supervisor
          |> Supervisor.which_children()
          |> Enum.find_value(fn
            {process_name, process_pid, _, _} when is_pid(process_pid) and process_name == name ->
              process_pid

            _ ->
              nil
          end)
      end
    rescue
      ArgumentError -> nil
      _ -> nil
    end
  end
end
