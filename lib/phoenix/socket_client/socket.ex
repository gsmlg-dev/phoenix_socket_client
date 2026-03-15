defmodule Phoenix.SocketClient.Socket do
  @moduledoc """
  The socket process for handling the WebSocket connection.
  """
  use GenServer
  require Logger

  alias Phoenix.SocketClient.ChannelManager
  alias Phoenix.SocketClient.Message
  alias Phoenix.SocketClient.Router
  alias Phoenix.SocketClient.Telemetry

  import Phoenix.SocketClient, only: [get_state: 2, put_state: 3, get_process_pid: 2]

  @type t :: %__MODULE__{
          sup_pid: pid() | atom(),
          status: :disconnected | :connecting | :connected,
          transport_ref: reference() | nil,
          transport_pid: pid() | nil,
          to_send_r: list(),
          to_send_count: non_neg_integer(),
          connect_start_time: integer() | nil,
          message_processor: pid() | nil,
          max_pending_messages: pos_integer(),
          last_activity: integer() | nil,
          hibernation_enabled: boolean(),
          heartbeat_timer: reference() | nil,
          pending_decodes: %{reference() => {pid() | atom(), String.t()}}
        }

  defstruct sup_pid: nil,
            status: :disconnected,
            transport_ref: nil,
            transport_pid: nil,
            to_send_r: [],
            to_send_count: 0,
            connect_start_time: nil,
            message_processor: nil,
            max_pending_messages: 500,
            last_activity: nil,
            hibernation_enabled: true,
            heartbeat_timer: nil,
            pending_decodes: %{}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: Enum.into(opts, [])
    registry_name = Keyword.get(opts, :registry_name)
    name = if registry_name, do: {:via, Registry, {registry_name, :socket}}, else: nil
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(map()) :: {:ok, t(), {:continue, :post_start}}
  def init(opts) do
    opts = if Keyword.keyword?(opts), do: Enum.into(opts, %{}), else: opts

    sup_pid = Map.get(opts, :sup_pid)
    _registry_name = Map.get(opts, :registry_name)
    Process.flag(:trap_exit, true)

    # Get message processor PID
    message_processor = get_process_pid(sup_pid, :message_processor)

    # Configure limits
    max_pending = Map.get(opts, :max_pending_messages, 500)
    hibernation_enabled = Map.get(opts, :hibernation_enabled, true)

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
    if get_state(sup_pid, :auto_connect) do
      Process.send_after(self(), :connect, 1_000)
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
        transport = socket_state.transport
        transport_opts = socket_state.transport_opts |> Keyword.put(:sender, self())

        # Use telemetry span for connection duration tracking
        Phoenix.SocketClient.Telemetry.span(
          [:phoenix, :socket_client, :connection],
          %{
            socket_ref: Phoenix.SocketClient.get_state(sup_pid, :socket_ref),
            url: url,
            transport: transport,
            transport_opts: transport_opts,
            sup_pid: sup_pid
          },
          fn ->
            case transport.open(url, transport_opts) do
              {:ok, transport_pid} ->
                transport_ref = Process.monitor(transport_pid)

                new_state = %__MODULE__{
                  state
                  | transport_pid: transport_pid,
                    status: :connecting,
                    transport_ref: transport_ref,
                    connect_start_time: System.monotonic_time()
                }

                update_socket_state_status(sup_pid, :connecting)
                {:ok, %{state: new_state, transport_pid: transport_pid}}

              {:error, reason} ->
                Phoenix.SocketClient.Telemetry.connection_error(%{
                  socket_ref: Phoenix.SocketClient.get_state(sup_pid, :socket_ref),
                  url: url,
                  error: reason,
                  transport: transport
                })

                {:error, %{reason: reason}}
            end
          end
        )
        |> case do
          {:ok, %{state: new_state}} ->
            {:noreply, new_state}

          {:error, %{reason: reason}} ->
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
    socket_state = Phoenix.SocketClient.get_state(sup_pid)
    socket_ref = Phoenix.SocketClient.get_state(sup_pid, :socket_ref)

    # Emit connection established stop event with duration
    if start_time do
      duration = System.monotonic_time() - start_time

      Phoenix.SocketClient.Telemetry.connection_established_stop(%{
        socket_ref: socket_ref,
        url: socket_state.url,
        transport_pid: transport_pid,
        duration: duration,
        status: :connected
      })
    else
      Phoenix.SocketClient.Telemetry.connection_established_stop(%{
        socket_ref: socket_ref,
        url: socket_state.url,
        transport_pid: transport_pid,
        status: :connected
      })
    end

    # Mark as connected and setup channels
    put_state(sup_pid, :reconnecting, false)
    join_initial_channels(sup_pid)
    rejoin_channels(sup_pid)

    # Start heartbeat timer
    heartbeat_interval = get_state(sup_pid, :heartbeat_interval) || 30_000
    heartbeat_timer = Process.send_after(self(), :heartbeat, heartbeat_interval)

    new_state = %__MODULE__{
      state
      | status: :connected,
        transport_pid: transport_pid,
        heartbeat_timer: heartbeat_timer
    }

    update_socket_state_status(sup_pid, :connected)

    case get_process_pid(sup_pid, :socket_state) do
      nil -> :ok
      state_pid -> Phoenix.SocketClient.Agent.update_connect_time(state_pid)
    end

    # Start tracking connection duration from establishment
    Phoenix.SocketClient.Telemetry.connection_established_start(%{
      socket_ref: socket_ref,
      url: socket_state.url,
      transport_pid: transport_pid,
      established_time: System.monotonic_time()
    })

    {:noreply, new_state}
  end

  @impl true
  @spec handle_info({:disconnected, any(), pid()}, t()) :: {:noreply, t()}
  def handle_info({:disconnected, reason, _transport_pid}, %{sup_pid: sup_pid} = state) do
    url = get_state(sup_pid, :url)
    socket_ref = Phoenix.SocketClient.get_state(sup_pid, :socket_ref)

    # Emit connection established stop event when connection ends
    Phoenix.SocketClient.Telemetry.connection_established_stop(%{
      socket_ref: socket_ref,
      url: url,
      reason: reason,
      status: :disconnected
    })

    case get_process_pid(sup_pid, :channel_manager) do
      nil -> :ok
      cm_pid -> ChannelManager.terminate(cm_pid)
    end

    {:noreply, close(reason, state)}
  end

  @impl true
  @spec handle_info({:receive, String.t()}, t()) :: {:noreply, t()}
  def handle_info({:receive, message}, %{sup_pid: _sup_pid} = state) do
    new_state = transport_receive(message, state)
    {:noreply, new_state}
  end

  @impl true
  @spec handle_info(:flush, t()) :: {:noreply, t()}
  def handle_info(:flush, %{sup_pid: _sup_pid} = state) do
    to_send = state.to_send_r || []

    state =
      Enum.reduce(to_send, state, fn msg, acc_state ->
        transport_send(msg, acc_state)
      end)

    {:noreply, %__MODULE__{state | to_send_r: [], to_send_count: 0}}
  end

  @spec handle_info(:heartbeat, t()) :: {:noreply, t()}
  def handle_info(:heartbeat, %{sup_pid: sup_pid, status: :connected} = state) do
    heartbeat_msg = %Message{
      topic: "phoenix",
      event: "heartbeat",
      payload: %{},
      ref: Message.generate_ref()
    }

    transport_send(heartbeat_msg, state)

    # Schedule next heartbeat
    heartbeat_interval = get_state(sup_pid, :heartbeat_interval) || 30_000
    heartbeat_timer = Process.send_after(self(), :heartbeat, heartbeat_interval)

    {:noreply, %{state | heartbeat_timer: heartbeat_timer}}
  end

  def handle_info(:heartbeat, state) do
    # Not connected, ignore heartbeat
    {:noreply, %{state | heartbeat_timer: nil}}
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
        {:noreply, %{state | to_send_r: new_to_send, to_send_count: state.to_send_count - 1}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:encode_result, ref, {:error, _reason}}, state) do
    # Remove failed encoding from pending list
    new_to_send = Enum.reject(state.to_send_r, fn {pending_ref, _} -> pending_ref == ref end)
    {:noreply, %{state | to_send_r: new_to_send, to_send_count: state.to_send_count - 1}}
  end

  @impl true
  @spec handle_info({:decode_result, reference(), {:ok, Message.t()}}, t()) :: {:noreply, t()}
  def handle_info({:decode_result, ref, {:ok, decoded_message}}, state) do
    # Get the original decode context
    case Map.fetch(state.pending_decodes, ref) do
      {:ok, {sup_pid, _raw_message}} ->
        # Route the decoded message
        socket_state = Phoenix.SocketClient.get_state(sup_pid)

        case Registry.lookup(socket_state.registry_name, decoded_message.topic) do
          [{pid, _}] -> send(pid, decoded_message)
          [] -> :noop
        end

        new_state = %{state | pending_decodes: Map.delete(state.pending_decodes, ref)}
        {:noreply, new_state}

      :error ->
        # No pending decode found
        {:noreply, state}
    end
  end

  def handle_info({:decode_result, ref, {:error, _reason}}, state) do
    # Clean up failed decode
    new_state = %{state | pending_decodes: Map.delete(state.pending_decodes, ref)}
    {:noreply, new_state}
  end

  @impl true
  @spec handle_info(:cleanup, t()) :: {:noreply, t()}
  def handle_info(:cleanup, state) do
    # Clean up stale pending messages (older than 30 seconds)
    current_time = System.monotonic_time(:millisecond)
    max_age = 30_000

    # Clean up stale pending decodes from state
    cleaned_pending_decodes =
      state.pending_decodes
      |> Enum.reject(fn {_ref, {sup_pid, _raw_message}} ->
        case get_state(sup_pid, :connect_time) do
          nil -> true
          connect_time -> current_time - connect_time > max_age
        end
      end)
      |> Map.new()

    # Limit queue size by dropping oldest messages if needed
    {final_to_send, final_count} =
      if state.to_send_count > state.max_pending_messages do
        {Enum.take(state.to_send_r, state.max_pending_messages), state.max_pending_messages}
      else
        {state.to_send_r, state.to_send_count}
      end

    trimmed_count = state.to_send_count - final_count

    if trimmed_count > 0 do
      Telemetry.execute(
        [:phoenix_socket_client, :socket, :cleanup],
        %{
          trimmed_messages: trimmed_count,
          remaining_messages: final_count
        },
        %{}
      )
    end

    new_state = %{
      state
      | to_send_r: final_to_send,
        to_send_count: final_count,
        pending_decodes: cleaned_pending_decodes
    }

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
    if state.status == :disconnected and Enum.empty?(state.to_send_r) do
      # Emit hibernation telemetry event
      Phoenix.SocketClient.Telemetry.optimization(:hibernation, %{
        socket_ref: Phoenix.SocketClient.get_state(state.sup_pid, :socket_ref),
        status: state.status,
        pending_messages: state.to_send_count,
        reason: :idle_hibernation
      })

      {:noreply, state, :hibernate}
    else
      # Not safe to hibernate right now
      Phoenix.SocketClient.Telemetry.optimization(:hibernation_skipped, %{
        socket_ref: Phoenix.SocketClient.get_state(state.sup_pid, :socket_ref),
        status: state.status,
        pending_messages: state.to_send_count,
        reason: :not_safe_to_hibernate
      })

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
      if state.to_send_count >= state.max_pending_messages do
        Telemetry.execute(
          [:phoenix_socket_client, :socket, :backpressure],
          %{
            pending_messages: state.to_send_count,
            max_pending: state.max_pending_messages
          },
          %{}
        )

        {:reply, {:error, :queue_full}, state}
      else
        # Encode message asynchronously
        ref = make_ref()

        Phoenix.SocketClient.MessageProcessor.encode(
          state.message_processor,
          message,
          self(),
          ref
        )

        # Store the message for sending once encoded
        new_state = %{
          state
          | to_send_r: [{ref, message} | state.to_send_r],
            to_send_count: state.to_send_count + 1
        }

        {:reply, message, new_state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  defp transport_receive(message, %{sup_pid: sup_pid} = state) do
    # Get message processor for async decoding
    message_processor = get_process_pid(sup_pid, :message_processor)

    if message_processor do
      # Decode message asynchronously
      ref = make_ref()
      Phoenix.SocketClient.MessageProcessor.decode(message_processor, message, self(), ref)

      # Store the pending decode operation in state
      %{state | pending_decodes: Map.put(state.pending_decodes, ref, {sup_pid, message})}
    else
      # Fallback to synchronous decoding
      fallback_decode_and_route(message, sup_pid)
      state
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
      if state.to_send_count >= state.max_pending_messages do
        Telemetry.execute(
          [:phoenix_socket_client, :socket, :backpressure],
          %{
            pending_messages: state.to_send_count,
            max_pending: state.max_pending_messages
          },
          %{}
        )

        state
      else
        # Encode message asynchronously
        ref = make_ref()

        Phoenix.SocketClient.MessageProcessor.encode(
          state.message_processor,
          message,
          self(),
          ref
        )

        # Store for sending once encoded
        %{
          state
          | to_send_r: [{ref, message} | state.to_send_r],
            to_send_count: state.to_send_count + 1
        }
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

  defp close(reason, %{sup_pid: sup_pid} = state) do
    # Cancel heartbeat timer if active
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    socket_state = Phoenix.SocketClient.get_state(sup_pid)
    socket_ref = Phoenix.SocketClient.get_state(sup_pid, :socket_ref)

    # Update socket state status
    update_socket_state_status(sup_pid, :disconnected)

    # Guard against nil socket_state when Agent is already down during shutdown
    if socket_state && socket_state.reconnect do
      put_state(sup_pid, :reconnecting, true)

      # Emit reconnection attempt event
      Phoenix.SocketClient.Telemetry.reconnection_attempt(%{
        socket_ref: socket_ref,
        url: socket_state.url,
        attempt: 1,
        reason: reason
      })

      Process.send_after(self(), :connect, socket_state.reconnect_interval)
    end

    %__MODULE__{state | status: :disconnected, heartbeat_timer: nil}
  end

  defp update_socket_state_status(sup_pid, new_status) do
    old_status = get_state(sup_pid, :status)
    url = get_state(sup_pid, :url)
    socket_ref = Phoenix.SocketClient.get_state(sup_pid, :socket_ref)

    # Emit status change event for monitoring
    Phoenix.SocketClient.Telemetry.emit_event(
      [:phoenix, :socket_client, :socket, :status_change],
      %{system_time: System.system_time()},
      %{
        socket_ref: socket_ref,
        url: url,
        old_status: old_status,
        new_status: new_status
      }
    )

    put_state(sup_pid, :status, new_status)
  end
end
