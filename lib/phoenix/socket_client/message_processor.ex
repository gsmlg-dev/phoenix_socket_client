defmodule Phoenix.SocketClient.MessageProcessor do
  @moduledoc """
  High-performance asynchronous message processor for Phoenix Socket Client.

  This module provides efficient, non-blocking JSON encoding/decoding
  operations with message batching, backpressure, and memory management
  for high-throughput scenarios.

  ## Features

  - Synchronous mode (default) for direct JSON encoding/decoding
  - Asynchronous mode with message batching for high-throughput scenarios
  - Bounded queues with backpressure (async mode)
  - Comprehensive monitoring and telemetry

  ## Sync Mode (Default)

  By default, `:sync_mode` is `true`. In this mode, `encode/4` and `decode/4`
  call `Jason.encode!/1` and `Jason.decode!/1` directly without going through
  the worker pool, batching, or binary pooling. This is the recommended mode
  for most use cases since JSON encoding/decoding takes microseconds.

  ## Async Mode

  Set `:sync_mode` to `false` to enable the async batch processing pipeline
  with worker pools, message batching, and binary pooling. This may be useful
  for extremely high-throughput scenarios.

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
    sync_mode: true,
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
    * `:sync_mode` - When true (default), encode/decode synchronously without worker pool
    * `:batch_size` - Maximum messages per batch (default: 20, async mode only)
    * `:batch_interval` - Batch timeout in ms (default: 10, async mode only)
    * `:max_queue_size` - Maximum queue size before backpressure (default: 1000, async mode only)
    * `:concurrency` - Number of worker processes (default: 8, async mode only)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: message_name(opts[:registry_name]))
  end

  @doc """
  Encodes a message.

  In sync mode (default), encodes directly and sends the result to the caller.
  In async mode, enqueues for batch processing by the worker pool.

  Returns `:ok` on success. The encoded result is sent as
  `{:encode_result, ref, {:ok, encoded}}` to the caller process.
  """
  @spec encode(pid(), Message.t(), pid(), reference()) :: :ok | {:error, term()}
  def encode(processor, message, caller \\ self(), ref \\ make_ref()) do
    GenServer.call(processor, {:enqueue, :encode, message, caller, ref}, 1000)
  end

  @doc """
  Decodes a message.

  In sync mode (default), decodes directly and sends the result to the caller.
  In async mode, enqueues for batch processing by the worker pool.

  Returns `:ok` on success. The decoded result is sent as
  `{:decode_result, ref, {:ok, decoded}}` to the caller process.
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
    sync_mode = Keyword.get(opts, :sync_mode, true)

    state =
      if sync_mode do
        # Sync mode: no worker pool, no binary pool, no route cache
        %__MODULE__{
          serializer: serializer,
          json_library: json_library,
          registry_name: registry_name,
          sync_mode: true
        }
      else
        # Async mode: start the full batch processing pipeline
        concurrency = Keyword.get(opts, :concurrency, @default_concurrency)

    state = %__MODULE__{
      serializer: serializer,
      json_library: json_library,
      registry_name: registry_name,
      binary_pool_pid: binary_pool_pid,
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      batch_interval: Keyword.get(opts, :batch_interval, @default_batch_interval),
      max_queue_size: Keyword.get(opts, :max_queue_size, @default_max_queue_size)
    }

    state =
      if sync_mode do
        state
      else
        {:ok, worker_sup} =
          start_worker_supervisor(concurrency, serializer, json_library, binary_pool_pid)

        %__MODULE__{state | sync_mode: false, worker_sup: worker_sup}
      end

    Telemetry.execute([:phoenix_socket_client, :message_processor, :started], %{}, %{
      registry_name: registry_name,
      sync_mode: sync_mode
    })

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, operation, data, caller, ref}, _from, %{sync_mode: true} = state) do
    # Sync mode: encode/decode directly and send result to caller
    result =
      case operation do
        :encode ->
          try do
            encoded = Message.encode!(state.serializer, data, state.json_library)
            {:ok, encoded}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        :decode ->
          try do
            decoded = Message.decode!(state.serializer, data, state.json_library)
            {:ok, decoded}
          catch
            kind, reason -> {:error, {kind, reason}}
          end
      end

    result_tag = if operation == :encode, do: :encode_result, else: :decode_result
    send(caller, {result_tag, ref, result})

    {:reply, :ok, state}
  end

  def handle_call({:enqueue, operation, data, caller, ref}, _from, state) do
    # Async mode: enqueue for batch processing
    queue_size = :queue.len(state.encode_queue) + :queue.len(state.decode_queue)

    if queue_size >= state.max_queue_size do
      Telemetry.execute(
        [:phoenix_socket_client, :message_processor, :backpressure],
        %{queue_size: queue_size},
        %{
          operation: operation
        }
      )

      {:reply, {:error, :queue_full}, state}
    else
      item = {operation, data, caller, ref}

      new_state =
        case operation do
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
      new_state = %{
        new_state
        | pending_replies: Map.put(new_state.pending_replies, ref, {caller, operation})
      }

      Telemetry.execute(
        [:phoenix_socket_client, :message_processor, :queued],
        %{
          queue_size: :queue.len(new_state.encode_queue) + :queue.len(new_state.decode_queue),
          operation: operation
        },
        %{}
      )

      {:reply, :ok, new_state}
    end
  end

  def handle_call(:stats, _from, %{sync_mode: true} = state) do
    stats = %{
      sync_mode: true,
      encode_queue_size: 0,
      decode_queue_size: 0,
      pending_replies: 0
    }

    {:reply, stats, state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      sync_mode: false,
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

    Telemetry.execute(
      [:phoenix_socket_client, :message_processor, :batch_completed],
      %{
        operation: operation,
        batch_size: length(results)
      },
      %{}
    )

    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private helper functions

  defp message_name(nil), do: __MODULE__
  defp message_name(registry_name), do: {:via, Registry, {registry_name, :message_processor}}

  # TODO: Refactor Task workers to GenServer workers (see GitHub issue #33).
  #
  # These Task workers run infinite receive loops, which is not idiomatic usage.
  # Tasks are designed for one-shot, finite work. Using them for long-running
  # message loops has the following limitations:
  #
  #   - If a worker crashes, any in-flight messages in its mailbox are lost.
  #   - Task.Supervisor features (async_nolink, yield, etc.) are not leveraged.
  #   - The restart strategy restarts the Task with a fresh loop, but pending
  #     messages sent to the old process PID are discarded.
  #
  # The correct approach would be to use GenServer workers under the supervisor,
  # each handling {:encode_batch, ...} and {:decode_batch, ...} via handle_info/2.
  # This is a larger refactor and is deferred for now.
  defp start_worker_supervisor(concurrency, serializer, json_library, binary_pool_pid) do
    children =
      for i <- 1..concurrency do
        Supervisor.child_spec(
          {Task, fn -> worker_loop(i, serializer, json_library, binary_pool_pid) end},
          id: i
        )
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

      {:empty, _queue} ->
        {:queue.new(), queue}
    end
  end

  defp take_batch_helper(batch, queue, 0), do: {batch, queue}

  defp take_batch_helper(batch, queue, remaining) do
    case :queue.out(queue) do
      {{:value, item}, remaining_queue} ->
        take_batch_helper([item | batch], remaining_queue, remaining - 1)

      {:empty, _queue} ->
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
