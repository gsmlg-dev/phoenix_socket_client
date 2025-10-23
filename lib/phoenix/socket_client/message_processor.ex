defmodule Phoenix.SocketClient.MessageProcessor do
  @moduledoc """
  High-performance asynchronous message processor for Phoenix Socket Client.

  This module provides efficient, non-blocking JSON encoding/decoding
  operations with message batching, backpressure, and memory management
  for high-throughput scenarios.

  ## Features

  - Asynchronous JSON encoding/decoding operations
  - Configurable message batching for network efficiency
  - Bounded queues with backpressure
  - Simple and robust design with minimal complexity
  - Comprehensive monitoring and telemetry

  ## Usage

  The processor is started automatically by the Socket supervisor and
  handles all message serialization/deserialization operations transparently.

  """

  use GenServer
  require Logger

  alias Phoenix.SocketClient.Message
  alias Phoenix.SocketClient.Telemetry

  @default_batch_size 20
  @default_batch_interval 10
  @default_max_queue_size 1000
  @default_concurrency 8

  defstruct [
    :serializer,
    :json_library,
    :registry_name,
    :binary_pool_pid,
    :route_cache_pid,
    encode_queue: :queue.new(),
    decode_queue: :queue.new(),
    encode_timer: nil,
    decode_timer: nil,
    batch_size: @default_batch_size,
    batch_interval: @default_batch_interval,
    max_queue_size: @default_max_queue_size,
    worker_sup: nil,
    pending_replies: %{}
  ]

  @doc """
  Starts the message processor with the given options.

  ## Options
    * `:serializer` - Message serializer module (required)
    * `:json_library` - JSON library module (defaults to Jason)
    * `:registry_name` - Registry name for channel lookup
    * `:batch_size` - Maximum messages per batch (default: 20)
    * `:batch_interval` - Batch timeout in ms (default: 10)
    * `:max_queue_size` - Maximum queue size before backpressure (default: 1000)
    * `:concurrency` - Number of worker processes (default: 8)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: message_name(opts[:registry_name]))
  end

  @doc """
  Encodes a message asynchronously.

  Returns immediately and sends the result back to the caller when complete.
  """
  @spec encode(pid(), Message.t(), pid(), reference()) :: :ok | {:error, term()}
  def encode(processor, message, caller \\ self(), ref \\ make_ref()) do
    GenServer.call(processor, {:enqueue, :encode, message, caller, ref}, 1000)
  end

  @doc """
  Decodes a message asynchronously.

  Returns immediately and sends the result back to the caller when complete.
  """
  @spec decode(pid(), String.t(), pid(), reference()) :: :ok | {:error, term()}
  def decode(processor, raw_message, caller \\ self(), ref \\ make_ref()) do
    GenServer.call(processor, {:enqueue, :decode, raw_message, caller, ref}, 1000)
  end

  @doc """
  Gets current processing statistics.
  """
  @spec stats(pid()) :: map()
  def stats(processor) do
    GenServer.call(processor, :stats, 1000)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    opts = if Keyword.keyword?(opts), do: opts, else: Enum.into(opts, [])

    serializer = Keyword.fetch!(opts, :serializer)
    json_library = Keyword.get(opts, :json_library, Jason)
    registry_name = Keyword.get(opts, :registry_name)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)

    # Start binary pool for JSON optimization
    {:ok, binary_pool_pid} = Phoenix.SocketClient.BinaryPool.start_link([
      pool_size: Keyword.get(opts, :binary_pool_size, 1000),
      cleanup_interval: Keyword.get(opts, :binary_cleanup_interval, 30_000),
      max_age: Keyword.get(opts, :binary_max_age, 300_000),
      registry_name: nil  # No registry for binary pool
    ])

    # Start route cache for message routing
    {:ok, route_cache_pid} = Phoenix.SocketClient.RouteCache.start_link([
      cache_size: Keyword.get(opts, :route_cache_size, 1000),
      ttl: Keyword.get(opts, :route_cache_ttl, 300_000),
      cleanup_interval: Keyword.get(opts, :route_cleanup_interval, 60_000),
      registry_name: nil  # No registry for route cache
    ])

    state = %__MODULE__{
      serializer: serializer,
      json_library: json_library,
      registry_name: registry_name,
      binary_pool_pid: binary_pool_pid,
      route_cache_pid: route_cache_pid,
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      batch_interval: Keyword.get(opts, :batch_interval, @default_batch_interval),
      max_queue_size: Keyword.get(opts, :max_queue_size, @default_max_queue_size)
    }

    # Start worker supervisor
    {:ok, worker_sup} = start_worker_supervisor(concurrency, serializer, json_library, binary_pool_pid)

    state = %{state | worker_sup: worker_sup}

    Telemetry.execute([:phoenix_socket_client, :message_processor, :started], %{}, %{registry_name: registry_name})

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, operation, data, caller, ref}, _from, state) do
    queue_size = :queue.len(state.encode_queue) + :queue.len(state.decode_queue)

    if queue_size >= state.max_queue_size do
      Telemetry.execute([:phoenix_socket_client, :message_processor, :backpressure], %{queue_size: queue_size}, %{
        operation: operation
      })

      {:reply, {:error, :queue_full}, state}
    else
      item = {operation, data, caller, ref}

      new_state = case operation do
        :encode ->
          %{state | encode_queue: :queue.in(item, state.encode_queue)}
        :decode ->
          %{state | decode_queue: :queue.in(item, state.decode_queue)}
      end

      # Start batch timer if not already running
      new_state = maybe_start_batch_timer(new_state, operation)

      # Process immediately if batch is full
      new_state = maybe_process_batch(new_state, operation)

      # Store pending reply tracking
      new_state = %{new_state | pending_replies: Map.put(new_state.pending_replies, ref, {caller, operation})}

      Telemetry.execute([:phoenix_socket_client, :message_processor, :queued], %{
        queue_size: :queue.len(new_state.encode_queue) + :queue.len(new_state.decode_queue),
        operation: operation
      }, %{})

      {:reply, :ok, new_state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      encode_queue_size: :queue.len(state.encode_queue),
      decode_queue_size: :queue.len(state.decode_queue),
      pending_replies: map_size(state.pending_replies),
      batch_size: state.batch_size,
      batch_interval: state.batch_interval,
      max_queue_size: state.max_queue_size
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:process_encode_batch, state) do
    {batch, new_encode_queue} = take_batch(state.encode_queue, state.batch_size)
    new_state = %{state | encode_queue: new_encode_queue, encode_timer: nil}

    if :queue.len(batch) > 0 do
      process_batch_async(:encode, batch, new_state)
    end

    {:noreply, new_state}
  end

  def handle_info(:process_decode_batch, state) do
    {batch, new_decode_queue} = take_batch(state.decode_queue, state.batch_size)
    new_state = %{state | decode_queue: new_decode_queue, decode_timer: nil}

    if :queue.len(batch) > 0 do
      process_batch_async(:decode, batch, new_state)
    end

    {:noreply, new_state}
  end

  def handle_info({:worker_result, operation, results}, state) do
    # Send results back to callers
    Enum.each(results, fn {ref, result} ->
      case Map.get(state.pending_replies, ref) do
        {caller, op} when is_pid(caller) and op == operation ->
          case operation do
            :encode -> send(caller, {:encode_result, ref, result})
            :decode -> send(caller, {:decode_result, ref, result})
          end
        _ ->
          # Caller may have died or operation mismatch, clean up
          :ok
      end
    end)

    # Remove processed replies from tracking
    refs = Enum.map(results, fn {ref, _} -> ref end)
    new_pending_replies = Map.drop(state.pending_replies, refs)

    new_state = %{state | pending_replies: new_pending_replies}

    Telemetry.execute([:phoenix_socket_client, :message_processor, :batch_completed], %{
      operation: operation,
      batch_size: length(results)
    }, %{})

    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private helper functions

  defp message_name(nil), do: __MODULE__
  defp message_name(registry_name), do: {:via, Registry, {registry_name, :message_processor}}

  defp start_worker_supervisor(concurrency, serializer, json_library, binary_pool_pid) do
    children = for i <- 1..concurrency do
      Supervisor.child_spec({Task, fn -> worker_loop(i, serializer, json_library, binary_pool_pid) end}, id: i)
    end

    Supervisor.start_link(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp worker_loop(worker_id, serializer, json_library, binary_pool_pid) do
    receive do
      {:encode_batch, batch, from} ->
        results = process_encode_batch_sync(batch, serializer, json_library, binary_pool_pid)
        send(from, {:worker_result, :encode, results})
        worker_loop(worker_id, serializer, json_library, binary_pool_pid)

      {:decode_batch, batch, from} ->
        results = process_decode_batch_sync(batch, serializer, json_library, binary_pool_pid)
        send(from, {:worker_result, :decode, results})
        worker_loop(worker_id, serializer, json_library, binary_pool_pid)
    end
  end

  defp process_encode_batch_sync(batch, serializer, json_library, binary_pool_pid) do
    Enum.map(batch, fn {_op, message, _caller, ref} ->
      try do
        # Encode the message
        result = Message.encode!(serializer, message, json_library)

        # Try to get from binary pool or store it
        pooled_result = Phoenix.SocketClient.BinaryPool.get_or_pool(binary_pool_pid, result)

        {ref, {:ok, pooled_result}}
      catch
        kind, reason ->
          {ref, {:error, {kind, reason}}}
      end
    end)
  end

  defp process_decode_batch_sync(batch, serializer, json_library, _binary_pool_pid) do
    Enum.map(batch, fn {_op, raw_message, _caller, ref} ->
      try do
        result = Message.decode!(serializer, raw_message, json_library)
        {ref, {:ok, result}}
      catch
        kind, reason ->
          {ref, {:error, {kind, reason}}}
      end
    end)
  end

  defp process_batch_async(operation, batch, state) do
    # Find available worker
    children = Supervisor.which_children(state.worker_sup)
    case Enum.find(children, fn {_id, pid, _worker, _modules} ->
      is_pid(pid) and Process.alive?(pid)
    end) do
      {_, pid, _worker, _modules} ->
        send(pid, {:"#{operation}_batch", batch, self()})
        state
      nil ->
        # No available workers, re-queue
        case operation do
          :encode ->
            %{state | encode_queue: :queue.join(batch, state.encode_queue)}
          :decode ->
            %{state | decode_queue: :queue.join(batch, state.decode_queue)}
        end
    end
  end

  defp take_batch(queue, max_size) do
    case :queue.out(queue) do
      {{:value, item}, remaining_queue} ->
        {batch, final_queue} = take_batch_helper([item], remaining_queue, max_size - 1)
        {:queue.from_list(batch), final_queue}
      {:empty} ->
        {:queue.new(), queue}
    end
  end

  defp take_batch_helper(batch, queue, 0), do: {batch, queue}
  defp take_batch_helper(batch, queue, remaining) do
    case :queue.out(queue) do
      {{:value, item}, remaining_queue} ->
        take_batch_helper([item | batch], remaining_queue, remaining - 1)
      {:empty} ->
        {batch, queue}
    end
  end

  defp maybe_start_batch_timer(state, operation) do
    case operation do
      :encode ->
        if state.encode_timer == nil and :queue.len(state.encode_queue) > 0 do
          timer = Process.send_after(self(), :process_encode_batch, state.batch_interval)
          %{state | encode_timer: timer}
        else
          state
        end
      :decode ->
        if state.decode_timer == nil and :queue.len(state.decode_queue) > 0 do
          timer = Process.send_after(self(), :process_decode_batch, state.batch_interval)
          %{state | decode_timer: timer}
        else
          state
        end
    end
  end

  defp maybe_process_batch(state, operation) do
    case operation do
      :encode ->
        if :queue.len(state.encode_queue) >= state.batch_size do
          {batch, new_encode_queue} = take_batch(state.encode_queue, state.batch_size)
          new_state = %{state | encode_queue: new_encode_queue}
          process_batch_async(:encode, batch, new_state)
        else
          state
        end
      :decode ->
        if :queue.len(state.decode_queue) >= state.batch_size do
          {batch, new_decode_queue} = take_batch(state.decode_queue, state.batch_size)
          new_state = %{state | decode_queue: new_decode_queue}
          process_batch_async(:decode, batch, new_state)
        else
          state
        end
    end
  end
end