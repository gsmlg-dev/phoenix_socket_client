defmodule PhoenixSocketClient.Socket.Channels do
  use DynamicSupervisor

  alias PhoenixSocketClient.Channel

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: supervisor_name(opts[:id]))
  end

  def whereis(id) do
    Process.whereis(supervisor_name(id))
  end

  def start_channel(pid, socket, topic, params) do
    spec = {Channel, {socket, topic, params}}
    DynamicSupervisor.start_child(pid, spec)
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
