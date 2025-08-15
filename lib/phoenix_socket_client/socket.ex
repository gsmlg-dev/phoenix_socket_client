defmodule PhoenixSocketClient.Socket do
  use Supervisor

  require Logger

  alias PhoenixSocketClient.Message
  alias PhoenixSocketClient.Socket.{Channels, Connection, State}

  def child_spec({opts, genserver_opts}) do
    %{
      id: genserver_opts[:id] || Keyword.get(opts, :id) || __MODULE__,
      start: {__MODULE__, :start_link, [opts, genserver_opts]}
    }
  end

  def child_spec(opts) do
    child_spec({opts, []})
  end

  def start_link(opts, genserver_opts \\ []) do
    Supervisor.start_link(__MODULE__, {opts, genserver_opts}, genserver_opts)
  end

  def stop(pid) do
    Supervisor.stop(pid)
  end

  @spec connected?(pid | atom) :: boolean
  def connected?(pid_or_name) do
    case whereis_state(pid_or_name) do
      nil -> false
      pid -> State.connected(pid)
    end
  end

  @doc false
  def push(pid, %Message{} = message) do
    state_pid = whereis_state(pid)
    push = State.push_message(state_pid, message)
    send(whereis_connection(pid), :flush)
    push
  end

  @doc false
  def channel_join(pid, topic, params) do
    channels_pid = whereis_channels(pid)
    Channels.start_channel(channels_pid, pid, topic, params)
  end

  @doc false
  def channel_leave(pid, channel) do
    channels_pid = whereis_channels(pid)
    Channels.terminate_channel(channels_pid, channel)
  end

  ## Callbacks
  @impl true
  def init({opts, genserver_opts}) do
    opts = Keyword.merge(opts, genserver_opts)
    id = opts[:id] || __MODULE__
    opts = Keyword.put(opts, :id, id)
    children = [
      {State, opts},
      {Channels, opts},
      {Connection, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp whereis_state(pid_or_name) do
    State.whereis(id_from_pid_or_name(pid_or_name))
  end

  defp whereis_channels(pid_or_name) do
    Channels.whereis(id_from_pid_or_name(pid_or_name))
  end

  defp whereis_connection(pid_or_name) do
    Connection.whereis(id_from_pid_or_name(pid_or_name))
  end

  defp id_from_pid_or_name(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} -> name
      _ -> nil
    end
  end

  defp id_from_pid_or_name(name) when is_atom(name) do
    name
  end
end
