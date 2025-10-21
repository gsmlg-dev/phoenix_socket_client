defmodule Phoenix.SocketClient do
  @moduledoc """
  The main API for the Phoenix Socket Client.
  """

  @doc """
  Starts the socket client supervisor.

  Delegates to `Phoenix.SocketClient.Supervisor.start_link/1`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: Phoenix.SocketClient.Supervisor

  @doc """
  Returns a child specification for the socket client supervisor.

  Delegates to `Phoenix.SocketClient.Supervisor.child_spec/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: Phoenix.SocketClient.Supervisor

  @doc """
  Connects the socket.
  """
  @spec connect(pid() | atom()) :: :ok | {:error, :no_socket_found}
  def connect(sup_pid) do
    case get_process_pid(sup_pid, :socket) do
      nil ->
        {:error, :no_socket_found}

      socket_pid ->
        send(socket_pid, :connect)
        :ok
    end
  end

  @doc false
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
      # First try to get registry name from the supervisor's state
      case Process.alive?(sup_pid) do
        false ->
          nil

        true ->
          # Get registry name from state for O(1) lookup
          case get_state(sup_pid, :registry_name) do
            nil ->
              # Fallback to the old way if registry not found
              fallback_process_discovery(sup_pid, name)

            registry_name ->
              # Use Registry for O(1) lookup instead of O(n) Supervisor.which_children()
              case Registry.lookup(registry_name, name) do
                [{pid, _}] when is_pid(pid) -> pid
                _ -> nil
              end
          end
      end
    rescue
      ArgumentError -> nil
      _ -> nil
    end
  end

  
  # Fallback to the old discovery method (only used during transition)
  defp fallback_process_discovery(sup_pid, name) do
    sup_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {process_name, process_pid, _, _} when is_pid(process_pid) and process_name == name ->
        process_pid
      _ ->
        nil
    end)
  end

  @doc """
  Gets a value from the socket state.
  """
  @spec get_state(pid() | atom(), atom()) :: any()
  def get_state(name, key)

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

  @doc """
  Gets the entire socket state.
  """
  @spec get_state(pid() | atom()) :: map()
  def get_state(name)

  def get_state(name) when is_atom(name) do
    case Process.whereis(name) do
      nil ->
        nil

      sup_pid ->
        get_state(sup_pid)
    end
  end

  def get_state(pid) when is_pid(pid) do
    state_pid = get_process_pid(pid, :socket_state)
    Phoenix.SocketClient.Agent.get_state(state_pid)
  end

  @doc """
  Puts a value into the socket state.
  """
  @spec put_state(pid() | atom(), atom(), any()) :: :ok
  def put_state(name, key, value)

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
  @spec channel_join(pid, binary, map) ::
          {:ok, pid} | {:error, :channel_manager_not_found | {:already_started, pid}}
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
  Updates the status of a channel. For internal use.
  """
  @spec update_channel_status(pid, pid, String.t(), atom(), map() | nil) :: :ok
  def update_channel_status(sup_pid, channel_pid, topic, status, params \\ nil) do
    state_pid = get_process_pid(sup_pid, :socket_state)

    Phoenix.SocketClient.Agent.update_channel_status(
      state_pid,
      channel_pid,
      topic,
      status,
      params
    )
  end

  @doc """
  Removes a channel from the list of joined channels. For internal use.
  """
  @spec remove_channel(pid, String.t()) :: :ok
  def remove_channel(sup_pid, topic) do
    reconnecting = get_state(sup_pid, :reconnecting)

    unless reconnecting do
      state_pid = get_process_pid(sup_pid, :socket_state)
      Phoenix.SocketClient.Agent.remove_channel(state_pid, topic)
    end
  end

  @doc """
  Pushes a message through the socket.
  """
  @spec push(pid | atom, Phoenix.SocketClient.Message.t()) ::
          Phoenix.SocketClient.Message.t() | no_return()
  def push(sup_pid, message) do
    case get_process_pid(sup_pid, :socket) do
      nil ->
        raise "Socket not found"

      pid ->
        GenServer.call(pid, {:push_message, message})
    end
  end

  @doc """
  Disconnects the socket.
  """
  @spec disconnect(pid | atom) :: :ok
  def disconnect(sup_pid) do
    case get_process_pid(sup_pid, :socket) do
      nil ->
        :ok

      socket_pid ->
        put_state(sup_pid, :reconnect, false)
        send(socket_pid, :disconnect)
        :ok
    end
  end
end
