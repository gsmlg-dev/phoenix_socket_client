defmodule PhoenixSocketClient.ChannelManager do
  use DynamicSupervisor

  alias PhoenixSocketClient.Channel
  import PhoenixSocketClient, only: [get_process_pid: 2]

  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: Map.to_list(opts)
    DynamicSupervisor.start_link(__MODULE__, opts)
  end

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
              if :sys.get_state(process_pid).topic == topic do
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

  def start_channel(sup_pid, topic, params, channel_module \\ Channel) do
    socket_pid = get_process_pid(sup_pid, :socket)
    cm_pid = get_process_pid(sup_pid, :channel_manager)

    spec =
      {channel_module, {sup_pid, socket_pid, topic, params}}
      |> Supervisor.child_spec(id: topic)

    case DynamicSupervisor.start_child(cm_pid, spec) do
      {:ok, channel_pid} -> {:ok, channel_pid}
      {:error, {:already_started, channel_pid}} -> {:error, {:already_started, channel_pid}}
      {:error, {:already_started, _, channel_pid}} -> {:error, {:already_started, channel_pid}}
      {:error, {:already_registered, channel_pid}} -> {:error, {:already_started, channel_pid}}
      error -> error
    end
  end

  def terminate_channel(pid, channel) do
    DynamicSupervisor.terminate_child(pid, channel)
  end

  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def terminate(cm_pid) when is_pid(cm_pid) do
    DynamicSupervisor.which_children(cm_pid)
    |> Enum.each(fn {_id, process_pid, _, _} ->
      DynamicSupervisor.terminate_child(cm_pid, process_pid)
    end)
  end
end
