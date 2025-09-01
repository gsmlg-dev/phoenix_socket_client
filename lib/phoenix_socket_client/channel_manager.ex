defmodule PhoenixSocketClient.ChannelManager do
  use DynamicSupervisor

  alias PhoenixSocketClient.Channel

  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: Map.to_list(opts)
    DynamicSupervisor.start_link(__MODULE__, opts)
  end

  def channel_pid(sup_pid, topic) when is_pid(id) do
    try do
      case Process.alive?(sup_pid) do
        false ->
          nil

        true ->
          sup_pid
          |> Supervisor.which_children()
          |> Enum.find_value(fn
            {process_name, process_pid, _, _}
            when is_pid(process_pid) and process_name == topic ->
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

  def start_channel(pid, socket, topic, params, channel_module \\ Channel) do
    spec =
      {channel_module, {socket, topic, params}}
      |> Supervisor.child_spec(id: topic)

    case DynamicSupervisor.start_child(pid, spec) do
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
end
