defmodule Phoenix.SocketClient.ChannelManager do
  @moduledoc """
  Dynamic supervisor for managing channel processes.

  This module supervises individual channel processes, handling their lifecycle
  from creation to termination. It provides functionality for:
  - Starting and supervising channel processes
  - Finding channel processes by topic
  - Managing channel lifecycle events

  ## Channel Lifecycle

  Channels are started as child processes under this supervisor when:
  - A client calls `Phoenix.SocketClient.Channel.join/3`
  - The socket connection is active and the channel join is successful

  Channels are terminated when:
  - The channel is left explicitly via `Channel.leave/1`
  - The socket connection is lost
  - The supervisor terminates
  """

  use DynamicSupervisor

  import Phoenix.SocketClient, only: [get_process_pid: 2, get_state: 2]

  @doc """
  Starts the ChannelManager dynamic supervisor.

  ## Parameters
    * `opts` - Configuration options (unused, required by DynamicSupervisor)

  ## Examples
      {:ok, pid} = Phoenix.SocketClient.ChannelManager.start_link([])
  """
  @spec start_link(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: Map.to_list(opts)
    DynamicSupervisor.start_link(__MODULE__, opts)
  end

  @doc """
  Finds the PID of a channel process by its topic.

  ## Parameters
    * `sup_pid` - The supervisor PID
    * `topic` - The channel topic to search for

  ## Returns
    * `pid` - The channel PID if found
    * `nil` - If no channel with the given topic exists

  ## Examples
      channel_pid = Phoenix.SocketClient.ChannelManager.channel_pid(sup_pid, "rooms:lobby")
  """
  @spec channel_pid(pid(), String.t()) :: pid() | nil
  def channel_pid(sup_pid, topic) when is_pid(sup_pid) do
    try do
      case Process.alive?(sup_pid) do
        false ->
          nil

        true ->
          sup_pid
          |> Supervisor.which_children()
          |> Enum.find_value(fn
            {_id, process_pid, _, _} ->
              # id - it is always :undefined for dynamic supervisors
              if GenServer.call(process_pid, :get_topic) == topic do
                process_pid
              else
                nil
              end

            _ ->
              nil
          end)
      end
    rescue
      ArgumentError -> nil
      _ -> nil
    end
  end

  @doc """
  Starts a channel process.
  """
  @spec start_channel(pid(), String.t(), map(), module()) :: {:ok, pid()} | {:error, term()}
  def start_channel(sup_pid, topic, params, channel_module \\ Phoenix.SocketClient.Channel.Room) do
    socket_pid = get_process_pid(sup_pid, :socket)
    cm_pid = get_process_pid(sup_pid, :channel_manager)
    registry_name = get_state(sup_pid, :registry_name)

    channel_module =
      (get_state(sup_pid, :topic_channel_map) || %{})
      |> Map.get(topic, channel_module)

    spec =
      {channel_module, {sup_pid, socket_pid, topic, params, registry_name}}
      |> Supervisor.child_spec(id: topic)

    case DynamicSupervisor.start_child(cm_pid, spec) do
      {:ok, channel_pid} ->
        Phoenix.SocketClient.update_channel_status(sup_pid, channel_pid, topic, :joining, params)
        {:ok, channel_pid}

      {:error, {:already_started, channel_pid}} ->
        {:error, {:already_started, channel_pid}}

      {:error, {:already_started, _, channel_pid}} ->
        {:error, {:already_started, channel_pid}}

      {:error, {:already_registered, channel_pid}} ->
        {:error, {:already_started, channel_pid}}

      error ->
        error
    end
  end

  def terminate_channel(pid, channel) do
    DynamicSupervisor.terminate_child(pid, channel)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Terminates all channel processes.
  """
  @spec terminate(pid()) :: :ok
  def terminate(cm_pid) when is_pid(cm_pid) do
    DynamicSupervisor.which_children(cm_pid)
    |> Enum.each(fn {_id, process_pid, _, _} ->
      DynamicSupervisor.terminate_child(cm_pid, process_pid)
    end)
  end
end
