defmodule PhoenixSocketClient.Socket do
  use GenServer
  require Logger

  alias PhoenixSocketClient.Message
  alias PhoenixSocketClient.Telemetry

  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: Map.to_list(opts)
    GenServer.start_link(__MODULE__, opts)
  end

  def whereis(_id) do
    nil
  end

  @doc """
  Checks if the socket is connected.
  """
  @spec connected?(pid | atom) :: boolean
  def connected?(socket_pid_or_name) do
    case resolve_socket_pid(socket_pid_or_name) do
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

  @doc false
  def resolve_socket_pid(socket_pid_or_name) do
    case socket_pid_or_name do
      pid when is_pid(pid) ->
        pid

      name when is_atom(name) ->
        case Process.whereis(name) do
          nil ->
            nil

          pid ->
            # Check if this is a supervisor or a socket process
            case Supervisor.which_children(pid) do
              children when is_list(children) ->
                # This is a supervisor, find the socket child
                case Enum.find(children, fn {id, _pid, _type, _modules} -> id == :socket end) do
                  {_id, socket_pid, _type, _modules} when is_pid(socket_pid) -> socket_pid
                  _ -> nil
                end

              _ ->
                # Assume this is already the socket process
                pid
            end
        end

      _ ->
        nil
    end
  end

  @doc """
  Joins a channel through the socket.
  """
  @spec channel_join(pid | atom, binary, map) :: {:ok, pid} | {:error, term}
  def channel_join(socket_pid_or_name, topic, params \\ %{}) do
    manager_pid = PhoenixSocketClient.ChannelManager.whereis(socket_pid_or_name)

    case manager_pid do
      nil ->
        {:error, :channel_manager_not_found}

      pid ->
        PhoenixSocketClient.ChannelManager.start_channel(pid, socket_pid_or_name, topic, params)
    end
  end

  @doc """
  Leaves a channel.
  """
  @spec channel_leave(pid | atom, pid) :: :ok
  def channel_leave(socket_pid_or_name, channel_pid) do
    case PhoenixSocketClient.ChannelManager.whereis(socket_pid_or_name) do
      nil -> :error
      manager_pid -> DynamicSupervisor.terminate_child(manager_pid, channel_pid)
    end
  end

  @doc """
  Pushes a message through the socket.
  """
  @spec push(pid | atom, Message.t()) :: Message.t()
  def push(socket_pid_or_name, message) do
    socket_pid = resolve_socket_pid(socket_pid_or_name)

    case socket_pid do
      nil ->
        raise "Socket #{inspect(socket_pid_or_name)} not found"

      pid ->
        GenServer.call(pid, {:push_message, message})
    end
  end

  @impl true
  def init(opts) do
    Logger.debug("Connection init: #{inspect(opts)}")
    send(self(), :connect)

    {:ok,
     %{
       opts: opts,
       status: :disconnected,
       transport_pid: nil
     }}
  end

  @impl true
  def handle_info(:connect, %{opts: opts} = state) do
    case opts[:url] do
      nil ->
        Logger.debug("Connection: no URL provided, skipping connection")
        {:noreply, state}

      url ->
        transport = opts[:transport] || PhoenixSocketClient.Transports.Websocket
        transport_opts = (opts[:transport_opts] || []) |> Keyword.put(:sender, self())

        Telemetry.socket_connecting(self(), url)

        case transport.open(url, transport_opts) do
          {:ok, transport_pid} ->
            Logger.debug("Connection: transport started #{inspect(transport_pid)}")
            state = %{state | transport_pid: transport_pid, status: :connecting}
            {:noreply, state}

          {:error, reason} ->
            Logger.debug("Connection: transport failed to start #{inspect(reason)}")
            Telemetry.socket_connection_error(self(), url, reason)
            {:noreply, close(reason, state)}
        end
    end
  end

  @impl true
  def handle_info({:connected, transport_pid}, %{opts: opts} = state) do
    Logger.debug("Connection: connected #{inspect(transport_pid)}")
    url = opts[:url]

    # Check if we should reject based on URL params
    uri = URI.parse(url)

    query_params =
      if uri.query do
        URI.decode_query(uri.query)
      else
        %{}
      end

    # Check if we should reject based on params
    params = opts[:params] || %{}

    reject_param = params["reject"] || query_params["reject"]

    if reject_param in ["true", true] do
      Logger.debug("Connection: rejecting due to params")
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
  def handle_info({:disconnected, reason, _transport_pid}, %{opts: opts} = state) do
    Logger.debug("Connection: disconnected #{inspect(reason)}")
    url = opts[:url]
    Telemetry.socket_disconnected(self(), url, reason)
    {:noreply, close(reason, state)}
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
    to_send = state[:to_send_r] || []
    Enum.each(to_send, &transport_send(&1, state))
    {:noreply, %{state | to_send_r: []}}
  end

  def handle_info(%PhoenixSocketClient.Message{} = message, state) do
    Logger.debug("Connection: received message struct #{inspect(message)}")
    # Handle message structs that might be sent directly
    channels_pid = PhoenixSocketClient.ChannelManager.whereis(state.opts[:id])
    children = Supervisor.which_children(channels_pid)

    case find_channel(children, message.topic) do
      nil -> :noop
      {_id, channel_pid, _type, _modules} -> send(channel_pid, message)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:closed, reason, _transport_pid}, state) do
    Logger.debug("Connection: closed #{inspect(reason)}")
    {:noreply, close(reason, state)}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state[:status] || :disconnected, state}
  end

  @impl true
  def handle_call({:push_message, message}, _from, %{opts: opts} = state) do
    transport_pid = state[:transport_pid]

    if transport_pid do
      protocol_vsn = Keyword.get(opts, :vsn, "1.0.0")
      serializer = PhoenixSocketClient.Message.serializer(protocol_vsn)
      json_library = opts[:json_library] || Jason

      send(transport_pid, {:send, Message.encode!(serializer, message, json_library)})
      {:reply, message, state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  defp transport_receive(message, %{opts: opts} = state) do
    protocol_vsn = Keyword.get(opts, :vsn, "1.0.0")
    serializer = PhoenixSocketClient.Message.serializer(protocol_vsn)
    json_library = opts[:json_library] || Jason
    decoded = Message.decode!(serializer, message, json_library)

    channels_pid = PhoenixSocketClient.ChannelManager.whereis(state.opts[:id])
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
    opts = state.opts
    transport_pid = state.transport_pid
    
    if transport_pid do
      protocol_vsn = Keyword.get(opts, :vsn, "1.0.0")
      serializer = PhoenixSocketClient.Message.serializer(protocol_vsn)
      json_library = opts[:json_library] || Jason
      
      send(transport_pid, {:send, Message.encode!(serializer, message, json_library)})
    end
  end

  defp close(reason, %{opts: opts} = state) do
    Logger.debug("Connection: closing connection, reason: #{inspect(reason)}")
    
    reconnect = Keyword.get(opts, :reconnect?, true)
    
    if reconnect do
      reconnect_interval = opts[:reconnect_interval] || 60_000
      Logger.debug("Connection: reconnecting in #{reconnect_interval}ms")
      url = opts[:url]
      Telemetry.reconnecting(self(), url, 1)
      Process.send_after(self(), :connect, reconnect_interval)
    end

    state
  end
end
