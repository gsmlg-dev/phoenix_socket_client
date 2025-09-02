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
      |> Supervisor.child_spec(id: :channel_manager),
      {Task,
       fn ->
         if get_state(sup_pid, :auto_connect) do
           connect(sup_pid)
         end
       end}
      |> Supervisor.child_spec(id: :post_start)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def connect(sup_pid) do
    case get_process_pid(sup_pid, :socket) do
      nil ->
        {:error, :no_socket_found}

      socket_pid ->
        send(socket_pid, :connect)
    end
  end

  def get_process_pid(sup_name, name) when is_atom(sup_name) do
    case Process.whereis(sup_name) do
      nil ->
        nil

      sup_pid ->
        get_process_pid(sup_pid, name)
    end
  end

  def get_process_pid(sup_pid, name) when is_pid(sup_pid) do
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

  def get_state(name, key) when is_atom(name) do
    case Process.whereis(name) do
      nil ->
        nil

      sup_pid ->
        get_state(sup_pid, key)
    end
  end

  def get_state(pid, key) when is_pid(pid) do
    state_pid = get_process_pid(pid, :socket_state)
    PhoenixSocketClient.SocketState.get(state_pid, key)
  end

  def put_state(name, key, value) when is_atom(name) do
    case Process.whereis(name) do
      nil ->
        nil

      sup_pid ->
        put_state(sup_pid, key, value)
    end
  end

  def put_state(pid, key, value) when is_pid(pid) do
    state_pid = get_process_pid(pid, :socket_state)
    PhoenixSocketClient.SocketState.put(state_pid, key, value)
  end
end
