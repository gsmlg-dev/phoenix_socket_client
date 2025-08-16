defmodule PhoenixSocketClient.ChannelManager do
  use DynamicSupervisor

  alias PhoenixSocketClient.Channel

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: supervisor_name(opts[:id]))
  end

  def whereis(id) do
    Process.whereis(supervisor_name(id))
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

  defp supervisor_name(id) do
    Module.concat(__MODULE__, id)
  end
end
