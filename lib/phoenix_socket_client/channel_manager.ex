defmodule PhoenixSocketClient.ChannelManager do
  use DynamicSupervisor

  alias PhoenixSocketClient.Channel

  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: Map.to_list(opts)
    DynamicSupervisor.start_link(__MODULE__, opts)
  end

  def whereis(id) when is_atom(id) do
    case Process.whereis(id) do
      nil -> nil
      server_pid -> PhoenixSocketClient.get_process_pid(server_pid, :channel_manager)
    end
  end

  def start_channel(pid, socket, topic, params) do
    child_spec = {Channel, {socket, topic, params}}

    case DynamicSupervisor.start_child(pid, child_spec) do
      {:ok, channel_pid} ->
        {:ok, channel_pid}

      {:error, {:already_started, channel_pid}} ->
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

  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
