defmodule Phoenix.SocketClient.Socket do
  @moduledoc """
  The socket process for handling the WebSocket connection.
  """
  use GenServer
  require Logger

  alias Phoenix.SocketClient.ChannelManager
  alias Phoenix.SocketClient.Message
  alias Phoenix.SocketClient.Telemetry
  alias Phoenix.SocketClient.Router

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
            to_send_r: [],
            connect_start_time: nil,
            message_processor: nil,
            max_pending_messages: 500,
            last_activity: nil,
            hibernation_enabled: true

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    registry_name = Keyword.get(opts, :registry_name)
    name = if registry_name, do: {registry_name, :socket}, else: nil
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(map()) :: {:ok, t(), {:continue, :post_start}}
  def init(%{sup_pid: sup_pid, registry_name: registry_name} = opts) do
    Process.flag(:trap_exit, true)

    # Get message processor PID
    message_processor = get_process_pid(sup_pid, :message_processor)

    # Configure limits
    max_pending = Keyword.get(opts, :max_pending_messages, 500)
    hibernation_enabled = Keyword.get(opts, :hibernation_enabled, true)

    # Set up periodic cleanup
    :timer.send_interval(30_000, :cleanup)

    current_time = System.monotonic_time(:millisecond)

    {:ok,
     %__MODULE__{
       sup_pid: sup_pid,
       message_processor: message_processor,
       max_pending_messages: max_pending,
       hibernation_enabled: hibernation_enabled,
       last_activity: current_time
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
    current_time = System.monotonic_time(:millisecond)
    new_state = %{state | last_activity: current_time}
    {:noreply, close(:normal, new_state)}
  end

  @spec handle_info(:connect, t()) :: {:noreply, t()}
  def handle_info(:connect, %{sup_pid: sup_pid} = state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)

    case socket_state.url do
      nil ->
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
            transport_ref = Process.monitor(transport_pid)

            state =
              %__MODULE__{
                state
                | transport_pid: transport_pid,
                  status: :connecting,
                  transport_ref: transport_ref,
                  connect_start_time: System.monotonic_time()
              }

            update_socket_state_status(sup_pid, :connecting)
            {:noreply, state}

          {:error, reason} ->
            Telemetry.socket_connection_error(self(), url, reason)
            {:noreply, close(reason, state)}
        end
    end
  end

  @impl true
  @spec handle_info({:connected, pid()}, t()) :: {:noreply, t()}
  def handle_info(
        {:connected, transport_pid},
        %{sup_pid: sup_pid, connect_start_time: start_time} = state
      ) do
    if start_time do
      duration = System.monotonic_time() - start_time
      socket_state = Phoenix.SocketClient.get_state(sup_pid)
      Telemetry.socket_connection_duration(self(), socket_state.url, duration)
    end

    socket_state = Phoenix.SocketClient.get_state(sup_pid)

    Telemetry.socket_connected(self(), socket_state.url)
    put_state(sup_pid, :reconnecting, false)
    join_initial_channels(sup_pid)
    rejoin_channels(sup_pid)
    state = %__MODULE__{state | status: :connected, transport_pid: transport_pid}
    update_socket_state_status(sup_pid, :connected)
    Phoenix.SocketClient.Agent.update_connect_time(sup_pid)
    {:noreply, state}
  end

  @impl true
  @spec handle_info({:disconnected, any(), pid()}, t()) :: {:noreply, t()}
  def handle_info({:disconnected, reason, _transport_pid}, %{sup_pid: sup_pid} = state) do
    url = get_state(sup_pid, :url)
    Telemetry.socket_disconnected(self(), url, reason)
    cm_pid = get_process_pid(sup_pid, :channel_manager)
    ChannelManager.terminate(cm_pid)
    {:noreply, close(reason, state)}
  end

  @impl true
  @spec handle_info({:receive, String.t()}, t()) :: {:noreply, t()}
  def handle_info({:receive, message}, %{sup_pid: _sup_pid} = state) do
    transport_receive(message, state)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(:flush, t()) :: {:noreply, t()}
  def handle_info(:flush, %{sup_pid: _sup_pid} = state) do
    to_send = state.to_send_r || []
    Enum.each(to_send, &transport_send(&1, state))
    {:noreply, %__MODULE__{state | to_send_r: []}}
  end

  @spec handle_info(Message.t(), t()) :: {:noreply, t()}
  def handle_info(%Message{} = message, %{sup_pid: sup_pid} = state) do
    # Handle message structs that might be sent directly using optimized routing
    socket_state = Phoenix.SocketClient.get_state(sup_pid)
    route_cache_pid = get_process_pid(sup_pid, :route_cache)

    routing_opts = [
      cache_pid: route_cache_pid,
      registry_name: socket_state.registry_name,
      use_cache: true,
      cache_on_hit: true
    ]

    case Router.route_message(message.topic, routing_opts) do
      {:ok, pid} -> send(pid, message)
      :error -> :noop
    end

    current_time = System.monotonic_time(:millisecond)
    new_state = %{state | last_activity: current_time}
    {:noreply, new_state}
  end

  @impl true
  @spec handle_info({:closed, any(), pid()}, t()) :: {:noreply, t()}
  def handle_info({:closed, reason, _transport_pid}, %{sup_pid: _sup_pid} = state) do
    {:noreply, close(reason, state)}
  end

  @impl true
  @spec handle_info({:encode_result, reference(), {:ok, String.t()}}, t()) :: {:noreply, t()}
  def handle_info({:encode_result, ref, {:ok, encoded_message}}, state) do
    # Find the original message and send it
    case Enum.find(state.to_send_r, fn {pending_ref, _} -> pending_ref == ref end) do
      {^ref, _original_message} ->
        # Send the encoded message to transport
        if state.transport_pid do
          send(state.transport_pid, {:send, encoded_message})
        end

        # Remove from pending list
        new_to_send = Enum.reject(state.to_send_r, fn {pending_ref, _} -> pending_ref == ref end)
        {:noreply, %{state | to_send_r: new_to_send}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:encode_result, ref, {:error, _reason}}, state) do
    # Remove failed encoding from pending list
    new_to_send = Enum.reject(state.to_send_r, fn {pending_ref, _} -> pending_ref == ref end)
    {:noreply, %{state | to_send_r: new_to_send}}
  end

  @impl true
  @spec handle_info({:decode_result, reference(), {:ok, Message.t()}}, t()) :: {:noreply, t()}
  def handle_info({:decode_result, ref, {:ok, decoded_message}}, state) do
    # Get the original decode context
    case Process.get({:pending_decode, ref}) do
      {sup_pid, _raw_message} ->
        # Route the decoded message
        socket_state = Phoenix.SocketClient.get_state(sup_pid)
        case Registry.lookup(socket_state.registry_name, decoded_message.topic) do
          [{pid, _}] -> send(pid, decoded_message)
          [] -> :noop
        end
        Process.delete({:pending_decode, ref})

      nil ->
        # No pending decode found
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:decode_result, ref, {:error, _reason}}, state) do
    # Clean up failed decode
    Process.delete({:pending_decode, ref})
    {:noreply, state}
  end

  @impl true
  @spec handle_info(:cleanup, t()) :: {:noreply, t()}
  def handle_info(:cleanup, state) do
    # Clean up stale pending messages (older than 30 seconds)
    current_time = System.monotonic_time(:millisecond)
    max_age = 30_000

    # Clean up process dictionary entries for pending decodes
    Process.get()
    |> Enum.filter(fn {key, _} ->
      case key do
        {:pending_decode, _ref} -> true
        _ -> false
      end
    end)
    |> Enum.each(fn {key, {sup_pid, _raw_message}} ->
      # Check if it's too old by checking socket connection time
      case get_state(sup_pid, :connect_time) do
        nil ->
          Process.delete(key)
        connect_time ->
          age = current_time - connect_time
          if age > max_age do
            Process.delete(key)
          end
      end
    end)

    # Clean up old pending messages in to_send_r
    filtered_to_send = Enum.filter(state.to_send_r, fn {ref, _message} ->
      # Keep only recent messages (this is a simple heuristic)
      # In practice, you might want to track timestamps per message
      true  # For now, keep all messages, but limit the queue size
    end)

    # Limit queue size by dropping oldest messages if needed
    final_to_send = if length(filtered_to_send) > state.max_pending_messages do
      Enum.take(filtered_to_send, state.max_pending_messages)
    else
      filtered_to_send
    end

    trimmed_count = length(state.to_send_r) - length(final_to_send)
    if trimmed_count > 0 do
      Telemetry.execute([:phoenix_socket_client, :socket, :cleanup], %{
        trimmed_messages: trimmed_count,
        remaining_messages: length(final_to_send)
      }, %{})
    end

    new_state = %{state | to_send_r: final_to_send}

    {:noreply, new_state}
  end

  @impl true
  @spec handle_info({:DOWN, reference(), :process, pid(), any()}, t()) :: {:noreply, t()}
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{sup_pid: _sup_pid, transport_ref: transport_ref, transport_pid: _transport_pid} = state
      ) do
    if ref == transport_ref do
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
  @spec handle_info(:hibernate_request, t()) :: {:noreply, t()}
  def handle_info(:hibernate_request, %{hibernation_enabled: false} = state) do
    # Hibernation disabled, ignore request
    {:noreply, state}
  end

  def handle_info(:hibernate_request, state) do
    # Only hibernate if disconnected and no pending messages
    if state.status == :disconnected and length(state.to_send_r) == 0 do
      Logger.debug("Socket process hibernating")
      {:noreply, state, :hibernate}
    else
      # Not safe to hibernate right now
      {:noreply, state}
    end
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
          {:reply, Message.t() | {:error, :not_connected | :queue_full}, t()}
  def handle_call({:push_message, message}, _from, state) do
    if state.transport_pid && state.message_processor do
      # Check queue size to prevent memory leaks
      if length(state.to_send_r) >= state.max_pending_messages do
        Telemetry.execute([:phoenix_socket_client, :socket, :backpressure], %{
          pending_messages: length(state.to_send_r),
          max_pending: state.max_pending_messages
        }, %{})
        {:reply, {:error, :queue_full}, state}
      else
        # Encode message asynchronously
        ref = make_ref()
        Phoenix.SocketClient.MessageProcessor.encode(state.message_processor, message, self(), ref)

        # Store the message for sending once encoded
        new_state = %{state | to_send_r: [{ref, message} | state.to_send_r]}
        {:reply, message, new_state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  defp transport_receive(message, %{sup_pid: sup_pid} = _state) do
    # Get message processor for async decoding
    message_processor = get_process_pid(sup_pid, :message_processor)

    if message_processor do
      # Decode message asynchronously
      ref = make_ref()
      Phoenix.SocketClient.MessageProcessor.decode(message_processor, message, self(), ref)

      # Store the pending decode operation
      Process.put({:pending_decode, ref}, {sup_pid, message})
    else
      # Fallback to synchronous decoding
      fallback_decode_and_route(message, sup_pid)
    end
  end

  defp fallback_decode_and_route(message, sup_pid) do
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

    if transport_pid && state.message_processor do
      # Check queue size to prevent memory leaks
      if length(state.to_send_r) >= state.max_pending_messages do
        Telemetry.execute([:phoenix_socket_client, :socket, :backpressure], %{
          pending_messages: length(state.to_send_r),
          max_pending: state.max_pending_messages
        }, %{})
        state
      else
        # Encode message asynchronously
        ref = make_ref()
        Phoenix.SocketClient.MessageProcessor.encode(state.message_processor, message, self(), ref)

        # Store for sending once encoded
        %{state | to_send_r: [{ref, message} | state.to_send_r]}
      end
    else
      # Fallback to synchronous encoding
      if transport_pid do
        socket_state = Phoenix.SocketClient.get_state(sup_pid)
        serializer = Phoenix.SocketClient.Message.serializer(socket_state.vsn)
        json_library = socket_state.json_library || Jason
        send(transport_pid, {:send, Message.encode!(serializer, message, json_library)})
      end
      state
    end
  end

  defp rejoin_channels(sup_pid) do
    joined_channels = get_state(sup_pid, :joined_channels)

    for {topic, %{status: :joined, params: params}} <- joined_channels do
      Phoenix.SocketClient.Channel.join(sup_pid, topic, params)
    end
  end

  defp join_initial_channels(sup_pid) do
    join_channels = get_state(sup_pid, :join_channels)

    for topic <- join_channels do
      Task.start(fn -> Phoenix.SocketClient.Channel.join(sup_pid, topic) end)
    end
  end

  defp close(_reason, %{sup_pid: sup_pid} = state) do
    socket_state = Phoenix.SocketClient.get_state(sup_pid)

    # Update socket state status
    update_socket_state_status(sup_pid, :disconnected)

    if socket_state.reconnect do
      put_state(sup_pid, :reconnecting, true)

      Telemetry.reconnecting(self(), socket_state.url, 1)
      Process.send_after(self(), :connect, socket_state.reconnect_interval)
    end

    %__MODULE__{state | status: :disconnected}
  end

  defp update_socket_state_status(sup_pid, new_status) do
    old_status = get_state(sup_pid, :status)
    url = get_state(sup_pid, :url)
    socket_pid = get_process_pid(sup_pid, :socket)
    Telemetry.socket_status_changed(socket_pid, url, old_status, new_status)
    put_state(sup_pid, :status, new_status)
  end
end
