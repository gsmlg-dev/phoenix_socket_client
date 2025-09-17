defmodule Phoenix.SocketClient.Socket do
  use GenServer

  alias Phoenix.SocketClient.ChannelManager
  alias Phoenix.SocketClient.Message
  alias Phoenix.SocketClient.Telemetry

  import Phoenix.SocketClient, only: [get_state: 2, put_state: 3, get_process_pid: 2]

  @type t :: %__MODULE__{
          sup_pid: pid(),
          status: :disconnected | :connecting | :connected,
          transport_ref: reference() | nil,
          transport_pid: pid() | nil,
          to_send_r: list()
        }

  defstruct sup_pid: nil,
            status: :disconnected,
            transport_ref: nil,
            transport_pid: nil,
            to_send_r: []

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  @spec init(map()) :: {:ok, t(), {:continue, :post_start}}
  def init(%{sup_pid: sup_pid} = _opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       sup_pid: sup_pid
     }, {:continue, :post_start}}
  end

  @impl true
  @spec handle_continue(:post_start, t()) :: {:noreply, t()}
  def handle_continue(:post_start, %{sup_pid: sup_pid} = state) do
    Process.sleep(1_000)

    if get_state(sup_pid, :auto_connect) do
      Process.send(self(), :connect, [:noconnect])
    end

    {:noreply, state}
  end

  @impl true
  @spec handle_info(:disconnect, t()) :: {:noreply, t()}
  def handle_info(:disconnect, state) do
    {:noreply, close(:normal, state)}
  end

  @spec handle_info(:connect, t()) :: {:noreply, t()}
  def handle_info(:connect, %{sup_pid: sup_pid} = state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)

    case socket_state.url do
      nil ->
        Telemetry.debug(self(), "Connection: no URL provided, skipping connection")
        {:noreply, state}

      url ->
        transport =
          socket_state.transport

        transport_opts =
          socket_state.transport_opts
          |> Keyword.put(:sender, self())

        Telemetry.socket_connecting(self(), url)

        case transport.open(url, transport_opts) do
          {:ok, transport_pid} ->
            Telemetry.debug(self(), "Connection: transport started", url, %{
              transport_pid: transport_pid
            })

            transport_ref = Process.monitor(transport_pid)

            state =
              %__MODULE__{
                state
                | transport_pid: transport_pid,
                  status: :connecting,
                  transport_ref: transport_ref
              }

            update_socket_state_status(sup_pid, :connecting)
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
  @spec handle_info({:connected, pid()}, t()) :: {:noreply, t()}
  def handle_info({:connected, transport_pid}, %{sup_pid: sup_pid} = state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)

    Telemetry.debug(self(), "Connection: connected", socket_state.url, %{
      transport_pid: transport_pid
    })

    Telemetry.socket_connected(self(), socket_state.url)
    put_state(sup_pid, :reconnecting, false)
    rejoin_channels(sup_pid)
    state = %__MODULE__{state | status: :connected, transport_pid: transport_pid}
    update_socket_state_status(sup_pid, :connected)
    {:noreply, state}
  end

  @impl true
  @spec handle_info({:disconnected, any(), pid()}, t()) :: {:noreply, t()}
  def handle_info({:disconnected, reason, _transport_pid}, %{sup_pid: sup_pid} = state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)
    Telemetry.debug(self(), "Connection: disconnected", socket_state.url, %{reason: reason})
    Telemetry.socket_disconnected(self(), socket_state.url, reason)
    cm_pid = get_process_pid(sup_pid, :channel_manager)
    ChannelManager.terminate(cm_pid)
    {:noreply, close(reason, state)}
  end

  @impl true
  @spec handle_info({:receive, String.t()}, t()) :: {:noreply, t()}
  def handle_info({:receive, message}, %{sup_pid: sup_pid} = state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)
    Telemetry.debug(self(), "Connection: received", socket_state.url, %{message: message})
    transport_receive(message, state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(:flush, t()) :: {:noreply, t()}
  def handle_info(:flush, %{sup_pid: sup_pid} = state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)
    Telemetry.debug(self(), "Connection: flushing messages", socket_state.url)
    to_send = state.to_send_r || []
    Enum.each(to_send, &transport_send(&1, state))
    {:noreply, %__MODULE__{state | to_send_r: []}}
  end

  @spec handle_info(Message.t(), t()) :: {:noreply, t()}
  def handle_info(%Message{} = message, %{sup_pid: sup_pid} = state) do
    url = get_state(sup_pid, :url)
    Telemetry.debug(self(), "Connection: received message struct", url, %{message: message})
    # Handle message structs that might be sent directly
    socket_state = Phoenix.SocketClient.get_state(sup_pid)

    case Registry.lookup(socket_state.registry_name, message.topic) do
      [{pid, _}] -> send(pid, message)
      [] -> :noop
    end

    {:noreply, state}
  end

  @impl true
  @spec handle_info({:closed, any(), pid()}, t()) :: {:noreply, t()}
  def handle_info({:closed, reason, _transport_pid}, %{sup_pid: sup_pid} = state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)
    Telemetry.debug(self(), "Connection: closed", socket_state.url, %{reason: reason})
    {:noreply, close(reason, state)}
  end

  @impl true
  @spec handle_info({:DOWN, reference(), :process, pid(), any()}, t()) :: {:noreply, t()}
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{sup_pid: sup_pid, transport_ref: transport_ref, transport_pid: transport_pid} = state
      ) do
    if ref == transport_ref do
      socket_state = Phoenix.SocketClient.get_state(sup_pid)

      Telemetry.debug(self(), "Connection process: DOWN", socket_state.url, %{
        reason: reason,
        transport_pid: transport_pid,
        transport_ref: transport_ref
      })

      {:noreply, close(:shutdown, state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  @spec handle_info({:EXIT, pid(), any()}, t()) :: {:noreply, t()}
  def handle_info(
        {:EXIT, _from_pid, reason},
        state
      ) do
    terminate(reason, state)

    {:noreply, close(reason, state)}
  end

  @impl true
  @spec terminate(any(), t()) :: :ok
  def terminate(_reason, _state) do
    :ok
  end

  @impl true
  @spec handle_call(:get_status, GenServer.from(), t()) ::
          {:reply, :connected | :connecting | :disconnected, t()}
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  @spec handle_call(:get_state, GenServer.from(), t()) :: {:reply, t(), t()}
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  @spec handle_call({:push_message, Message.t()}, GenServer.from(), t()) ::
          {:reply, Message.t() | {:error, :not_connected}, t()}
  def handle_call({:push_message, message}, _from, %{sup_pid: sup_pid} = state) do
    if state.transport_pid do
      socket_state = Phoenix.SocketClient.get_state(sup_pid)
      serializer = Phoenix.SocketClient.Message.serializer(socket_state.vsn)
      json_library = socket_state.json_library || Jason

      send(state.transport_pid, {:send, Message.encode!(serializer, message, json_library)})
      {:reply, message, state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call(not_matched, from, state) do
    IO.inspect({:not_matched_handle_call, not_matched, from, state})
    {:noreply, state}
  end

  defp transport_receive(message, %{sup_pid: sup_pid} = _state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)
    serializer = Phoenix.SocketClient.Message.serializer(socket_state.vsn)
    json_library = socket_state.json_library || Jason
    decoded = Message.decode!(serializer, message, json_library)

    case Registry.lookup(socket_state.registry_name, decoded.topic) do
      [{pid, _}] -> send(pid, decoded)
      [] -> :noop
    end
  end

  defp transport_send(message, %{sup_pid: sup_pid} = state) do
    transport_pid = state.transport_pid

    if transport_pid do
      socket_state = Phoenix.SocketClient.get_state(sup_pid)
      serializer = Phoenix.SocketClient.Message.serializer(socket_state.vsn)
      json_library = socket_state.json_library || Jason

      send(transport_pid, {:send, Message.encode!(serializer, message, json_library)})
    end
  end

  defp rejoin_channels(sup_pid) do
    joined_channels = get_state(sup_pid, :joined_channels)

    for {topic, %{status: :joined, params: params}} <- joined_channels do
      Phoenix.SocketClient.Channel.join(sup_pid, topic, params)
    end
  end

  defp close(reason, %{sup_pid: sup_pid} = state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)
    Telemetry.debug(self(), "Connection: closing connection", socket_state.url, %{reason: reason})

    # Update socket state status
    update_socket_state_status(sup_pid, :disconnected)

    if socket_state.reconnect do
      put_state(sup_pid, :reconnecting, true)

      Telemetry.debug(self(), "Connection: reconnecting", socket_state.url, %{
        interval: socket_state.reconnect_interval
      })

      Telemetry.reconnecting(self(), socket_state.url, 1)
      Process.send_after(self(), :connect, socket_state.reconnect_interval)
    end

    %__MODULE__{state | status: :disconnected}
  end

  defp update_socket_state_status(sup_pid, status) do
    put_state(sup_pid, :status, status)
  end
end
