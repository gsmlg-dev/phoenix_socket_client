defmodule PhoenixSocketClient.Socket do
  use GenServer

  alias PhoenixSocketClient.Message
  alias PhoenixSocketClient.Telemetry

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Checks if the socket is connected.
  """
  @spec connected?(pid | atom) :: boolean
  def connected?(sup_pid) do
    socket_pid = PhoenixSocketClient.get_process_pid(sup_pid, :socket)

    case socket_pid do
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
  @spec channel_join(pid, binary, map) :: {:ok, pid} | {:error, term}
  def channel_join(sup_pid, topic, params \\ %{}) do
    manager_pid = PhoenixSocketClient.get_process_pid(sup_pid, :channel_manager)
    socket_pid = PhoenixSocketClient.get_process_pid(sup_pid, :socket)

    case manager_pid do
      nil ->
        {:error, :channel_manager_not_found}

      pid ->
        PhoenixSocketClient.ChannelManager.start_channel(pid, socket_pid, topic, params)
    end
  end

  @doc """
  Leaves a channel.
  """
  @spec channel_leave(pid, pid) :: :ok
  def channel_leave(sup_pid, channel_pid) do
    case PhoenixSocketClient.get_process_pid(sup_pid, :channel_manager) do
      nil -> :error
      manager_pid -> DynamicSupervisor.terminate_child(manager_pid, channel_pid)
    end
  end

  @doc """
  Pushes a message through the socket.
  """
  @spec push(pid | atom, Message.t()) :: Message.t()
  def push(sup_pid, message) do
    socket_pid = PhoenixSocketClient.get_process_pid(sup_pid, :socket)

    case socket_pid do
      nil ->
        raise "Socket #{inspect(socket_pid_or_name)} not found"

      pid ->
        GenServer.call(pid, {:push_message, message})
    end
  end

  @impl true
  def init(opts) do
    Telemetry.debug(self(), "Connection init", nil, %{opts: opts})
    send(self(), :connect)

    {:ok,
     %{
       sup_pid: opts[:sup_pid],
       status: :disconnected,
       transport_pid: nil
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{sup_pid: sup_pid} = state) do
    case PhoenixSocketClient.get(sup_pid, :url) do
      nil ->
        Telemetry.debug(self(), "Connection: no URL provided, skipping connection")
        {:noreply, state}

      url ->
        transport =
          PhoenixSocketClient.get(sup_pid, :transport) || PhoenixSocketClient.Transports.Websocket

        transport_opts =
          (PhoenixSocketClient.get(sup_pid, :transport_opts) || [])
          |> Keyword.put(:sender, self())

        Telemetry.socket_connecting(self(), url)

        case transport.open(url, transport_opts) do
          {:ok, transport_pid} ->
            Telemetry.debug(self(), "Connection: transport started", url, %{
              transport_pid: transport_pid
            })

            state = %{state | transport_pid: transport_pid, status: :connecting}
            {:noreply, state}

          {:error, reason} ->
            Telemetry.debug(self(), "Connection: transport failed to start", url, %{
              reason: reason
            })

            Telemetry.socket_connection_error(self(), url, reason)
            {:noreply, close(reason, state)}
        end
    end
  end

  @impl true
  def handle_info(:connect, %{sup_pid: sup_pid} = state) do
    case PhoenixSocketClient.get(sup_pid, :url) do
      nil ->
        Telemetry.debug(self(), "Connection: no URL provided, skipping connection")
        {:noreply, state}

      url ->
        transport =
          PhoenixSocketClient.get(sup_pid, :transport) || PhoenixSocketClient.Transports.Websocket

        transport_opts =
          (PhoenixSocketClient.get(sup_pid, :transport_opts) || [])
          |> Keyword.put(:sender, self())

        Telemetry.socket_connecting(self(), url)

        case transport.open(url, transport_opts) do
          {:ok, transport_pid} ->
            Telemetry.debug(self(), "Connection: transport started", url, %{
              transport_pid: transport_pid
            })

            state = %{state | transport_pid: transport_pid, status: :connecting}
            {:noreply, state}

          {:error, reason} ->
            Telemetry.debug(self(), "Connection: transport failed to start", url, %{
              reason: reason
            })

            Telemetry.socket_connection_error(self(), url, reason)
            {:noreply, close(reason, state)}
        end
    end
  end

  @impl true
  def handle_info({:connected, transport_pid}, %{sup_pid: sup_pid} = state) do
    url = PhoenixSocketClient.get(sup_pid, :url)
    Telemetry.debug(self(), "Connection: connected", url, %{transport_pid: transport_pid})

    # Check if we should reject based on URL params
    uri = URI.parse(url)

    query_params =
      if uri.query do
        URI.decode_query(uri.query)
      else
        %{}
      end

    # Check if we should reject based on params
    params = PhoenixSocketClient.get(sup_pid, :params)

    reject_param = params["reject"] || query_params["reject"]

    if reject_param in ["true", true] do
      Telemetry.debug(self(), "Connection: rejecting due to params", url)
      Telemetry.socket_connection_error(self(), url, :rejected)
      send(transport_pid, :close)
      {:noreply, close(:rejected, state)}
    else
      Telemetry.socket_connected(self(), url)
      state = %{state | status: :connected, transport_pid: transport_pid}
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:disconnected, reason, _transport_pid}, %{sup_pid: sup_pid} = state) do
    url = PhoenixSocketClient.get(sup_pid, :url)
    Telemetry.debug(self(), "Connection: disconnected", url, %{reason: reason})
    Telemetry.socket_disconnected(self(), url, reason)
    {:noreply, close(reason, state)}
  end

  @impl true
  def handle_info({:receive, message}, %{sup_pid: sup_pid} = state) do
    url = PhoenixSocketClient.get(sup_pid, :url)
    Telemetry.debug(self(), "Connection: received", url, %{message: message})
    transport_receive(message, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, %{sup_pid: sup_pid} = state) do
    url = PhoenixSocketClient.get(sup_pid, :url)
    Telemetry.debug(self(), "Connection: flushing messages", url)
    to_send = state[:to_send_r] || []
    Enum.each(to_send, &transport_send(&1, state))
    {:noreply, %{state | to_send_r: []}}
  end

  def handle_info(%PhoenixSocketClient.Message{} = message, %{sup_pid: sup_pid} = state) do
    url = PhoenixSocketClient.get(sup_pid, :url)
    Telemetry.debug(self(), "Connection: received message struct", url, %{message: message})
    # Handle message structs that might be sent directly
    channels_pid = PhoenixSocketClient.get_process_pid(sup_pid, :channel_manager)
    children = Supervisor.which_children(channels_pid)

    case find_channel(children, message.topic) do
      nil -> :noop
      {_id, channel_pid, _type, _modules} -> send(channel_pid, message)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:closed, reason, _transport_pid}, %{sup_pid: sup_pid} = state) do
    url = PhoenixSocketClient.get(sup_pid, :url)
    Telemetry.debug(self(), "Connection: closed", url, %{reason: reason})
    {:noreply, close(reason, state)}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state[:status] || :disconnected, state}
  end

  @impl true
  def handle_call({:push_message, message}, _from, %{sup_pid: sup_pid} = state) do
    transport_pid = state[:transport_pid]

    if transport_pid do
      protocol_vsn = PhoenixSocketClient.get(sup_pid, :vsn)
      serializer = PhoenixSocketClient.Message.serializer(protocol_vsn)
      json_library = PhoenixSocketClient.get(sup_pid, :json_library) || Jason

      send(transport_pid, {:send, Message.encode!(serializer, message, json_library)})
      {:reply, message, state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  defp transport_receive(message, %{sup_pid: sup_pid} = _state) do
    protocol_vsn = PhoenixSocketClient.get(sup_pid, :vsn)
    serializer = PhoenixSocketClient.Message.serializer(protocol_vsn)
    json_library = PhoenixSocketClient.get(sup_pid, :json_library) || Jason
    decoded = Message.decode!(serializer, message, json_library)

    channels_pid = PhoenixSocketClient.get_process_pid(sup_pid, :channel_manager)
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

  defp transport_send(message, %{sup_pid: sup_pid} = state) do
    transport_pid = state.transport_pid

    if transport_pid do
      protocol_vsn = PhoenixSocketClient.get(sup_pid, :vsn)
      serializer = PhoenixSocketClient.Message.serializer(protocol_vsn)
      json_library = PhoenixSocketClient.get(sup_pid, :json_library) || Jason

      send(transport_pid, {:send, Message.encode!(serializer, message, json_library)})
    end
  end

  defp close(reason, %{sup_pid: sup_pid} = state) do
    url = PhoenixSocketClient.get(sup_pid, :url)
    Telemetry.debug(self(), "Connection: closing connection", url, %{reason: reason})

    reconnect = PhoenixSocketClient.get(sup_pid, :reconnect?)

    if reconnect do
      reconnect_interval = PhoenixSocketClient.get(sup_pid, :reconnect_interval)
      Telemetry.debug(self(), "Connection: reconnecting", url, %{interval: reconnect_interval})
      Telemetry.reconnecting(self(), url, 1)
      Process.send_after(self(), :connect, reconnect_interval)
    end

    state
  end
end
