defmodule PhoenixSocketClient.ChannelManager do
  use DynamicSupervisor

  alias PhoenixSocketClient.Channel

  def start_link({_server_pid, opts}) do
    DynamicSupervisor.start_link(__MODULE__, opts)
  end

  def whereis(id) when is_atom(id) do
    case Process.whereis(id) do
      nil -> nil
      server_pid -> PhoenixSocketClient.get_process_pid(server_pid, :channel_manager)
    end
  end

  def whereis(server_pid) when is_pid(server_pid) do
    PhoenixSocketClient.get_process_pid(server_pid, :channel_manager)
  end

  def start_channel(pid, socket, topic, params) do
    spec = %{
      id: topic,
      start: {Channel, :start_link, [{socket, topic, params}]}
    }

    case DynamicSupervisor.start_child(pid, spec) do
      {:error, {:already_started, _}} -> {:error, {:already_started, pid}}
      result -> result
    end
  end

  def terminate_channel(pid, channel) do
    DynamicSupervisor.terminate_child(pid, channel)
  end

  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

end
