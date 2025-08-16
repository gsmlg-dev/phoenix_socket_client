defmodule PhoenixSocketClient.Socket do
  use GenServer
  require Logger

  alias PhoenixSocketClient.Message
  alias PhoenixSocketClient.SocketState
  alias PhoenixSocketClient.ChannelManager

  def start_link({server_pid, opts}) do
    GenServer.start_link(__MODULE__, {server_pid, opts})
  end

  def whereis(id) do
    Process.whereis(connection_name(id))
  end

  @impl true
  def init({server_pid, opts}) do
    Logger.debug("Connection init: #{inspect(opts)}")
    send(self(), :connect)
    {:ok, %{server_pid: server_pid}}
  end

  @impl true
  def handle_info(:connect, %{server_pid: server_pid} = state) do
    Logger.debug("Connection: connecting")
    state_pid = PhoenixSocketClient.get_process_pid(server_pid, :socket_state)
    transport = SocketState.get(state_pid, :transport)
    url = SocketState.get(state_pid, :url)
    transport_opts = SocketState.get(state_pid, :transport_opts) |> Keyword.put(:sender, self())

    case transport.open(url, transport_opts) do
      {:ok, transport_pid} ->
        Logger.debug("Connection: transport started #{inspect(transport_pid)}")
        SocketState.put(state_pid, :transport_pid, transport_pid)
        {:noreply, state}

      {:error, reason} ->
        Logger.debug("Connection: transport failed to start #{inspect(reason)}")
        {:noreply, close(reason, state)}
    end
  end

  @impl true
  def handle_info({:connected, transport_pid}, state) do
    Logger.debug("Connection: connected #{inspect(transport_pid)}")
    state_pid = SocketState.whereis(state.id)
    current_transport_pid = SocketState.get(state_pid, :transport_pid)

    if transport_pid == current_transport_pid do
      SocketState.put(state_pid, :status, :connected)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:disconnected, reason, transport_pid}, state) do
    Logger.debug("Connection: disconnected #{inspect(reason)}")
    state_pid = SocketState.whereis(state.id)
    current_transport_pid = SocketState.get(state_pid, :transport_pid)

    if transport_pid == current_transport_pid do
      close(reason, state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:receive, message}, state) do
    Logger.debug("Connection: received #{inspect(message)}")
    transport_receive(message, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    Logger.debug("Connection: flushing messages")
    state_pid = SocketState.whereis(state.id)
    to_send = SocketState.pop_all_to_send(state_pid)
    Enum.each(to_send, &transport_send(&1, state))
    {:noreply, state}
  end

  @impl true
  def handle_info({:closed, reason, transport_pid}, state) do
    Logger.debug("Connection: closed #{inspect(reason)}")
    state_pid = SocketState.whereis(state.id)
    current_transport_pid = SocketState.get(state_pid, :transport_pid)

    if transport_pid == current_transport_pid do
      close(reason, state)
    end

    {:noreply, state}
  end

  defp transport_receive(message, state) do
    state_pid = SocketState.whereis(state.id)
    serializer = SocketState.get(state_pid, :serializer)
    json_library = SocketState.get(state_pid, :json_library)
    decoded = Message.decode!(serializer, message, json_library)

    channels_pid = ChannelManager.whereis(state.id)
    children = Supervisor.which_children(channels_pid)

    case find_channel(children, decoded.topic) do
      nil -> :noop
      {_id, channel_pid, _type, _modules} -> send(channel_pid, decoded)
    end
  end

  defp find_channel(children, topic) do
    Enum.find(children, fn {_id, pid, _type, _modules} ->
      :sys.get_state(pid).topic == topic
    end)
  end

  defp transport_send(message, state) do
    state_pid = SocketState.whereis(state.id)
    transport_pid = SocketState.get(state_pid, :transport_pid)
    serializer = SocketState.get(state_pid, :serializer)
    json_library = SocketState.get(state_pid, :json_library)
    send(transport_pid, {:send, Message.encode!(serializer, message, json_library)})
  end

  defp close(reason, state) do
    Logger.debug("Connection: closing connection, reason: #{inspect(reason)}")
    state_pid = SocketState.whereis(state.id)
    SocketState.put(state_pid, :status, :disconnected)
    reconnect = SocketState.get(state_pid, :reconnect)

    if reconnect do
      reconnect_interval = SocketState.get(state_pid, :reconnect_interval)
      Logger.debug("Connection: reconnecting in #{reconnect_interval}ms")
      Process.send_after(self(), :connect, reconnect_interval)
    end

    state
  end

  defp connection_name(id) do
    Module.concat(__MODULE__, id)
  end
end
