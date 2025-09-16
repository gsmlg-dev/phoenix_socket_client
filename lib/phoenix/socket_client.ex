defmodule Phoenix.SocketClient do
  @moduledoc """
  A Supervisor for starting, supervising, and managing socket connections.
  """

  @spec child_spec(keyword) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: Phoenix.SocketClient.Supervisor

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
    Phoenix.SocketClient.Agent.get(state_pid, key)
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
    Phoenix.SocketClient.Agent.put(state_pid, key, value)
  end

  @doc """
  Checks if the socket is connected.
  """
  @spec connected?(pid | atom) :: boolean
  def connected?(sup_pid) do
    case get_process_pid(sup_pid, :socket) do
      nil ->
        false

      pid ->
        try do
          GenServer.call(pid, :get_status, 5_000) == :connected
        catch
          :exit, _ -> false
        end
    end
  end

  @doc """
  Joins a channel through the socket.
  """
  @spec channel_join(pid, binary, map) :: {:ok, pid} | {:error, term}
  def channel_join(sup_pid, topic, params \\ %{}) do
    case get_process_pid(sup_pid, :channel_manager) do
      nil ->
        {:error, :channel_manager_not_found}

      _manager_pid ->
        Phoenix.SocketClient.ChannelManager.start_channel(sup_pid, topic, params)
    end
  end

  @doc """
  Leaves a channel.
  """
  @spec channel_leave(pid, pid) :: :ok
  def channel_leave(sup_pid, channel_pid) do
    case get_process_pid(sup_pid, :channel_manager) do
      nil -> :error
      manager_pid -> DynamicSupervisor.terminate_child(manager_pid, channel_pid)
    end
  end

  @doc """
  Pushes a message through the socket.
  """
  @spec push(pid | atom, Phoenix.SocketClient.Message.t()) :: Phoenix.SocketClient.Message.t()
  def push(sup_pid, message) do
    case get_process_pid(sup_pid, :socket) do
      nil ->
        raise "Socket not found"

      pid ->
        GenServer.call(pid, {:push_message, message})
    end
  end
end
