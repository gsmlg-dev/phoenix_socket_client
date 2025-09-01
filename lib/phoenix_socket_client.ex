defmodule PhoenixSocketClient do
  @moduledoc """
  A Supervisor for starting, supervising, and managing socket connections.
  """
  use Supervisor

  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name)

    if is_nil(name) do
      Supervisor.start_link(__MODULE__, opts)
    else
      Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    sup_pid = self()
    opts = opts |> Map.put(:sup_pid, sup_pid)

    children = [
      {PhoenixSocketClient.SocketState, opts}
      |> Supervisor.child_spec(id: :socket_state),
      {PhoenixSocketClient.Socket, opts}
      |> Supervisor.child_spec(id: :socket),
      {PhoenixSocketClient.ChannelManager, opts}
      |> Supervisor.child_spec(id: :channel_manager)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def get_process_pid(sup_pid, name) do
    try do
      case Process.alive?(sup_pid) do
        false ->
          nil

        true ->
          sup_pid
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

  def get(pid, key) do
    state_pid = get_process_pid(pid, :socket_state)
    PhoenixSocketClient.SocketState.get(state_pid, key)
  end

  def put_state(pid, key, value) do
    state_pid = get_process_pid(pid, :socket_state)
    PhoenixSocketClient.SocketState.put(state_pid, key, value)
  end
end
