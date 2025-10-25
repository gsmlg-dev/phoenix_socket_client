defmodule Phoenix.SocketClient.Telemetry do
  @moduledoc """
  Comprehensive Telemetry integration for Phoenix.SocketClient.

  This module provides telemetry events with duration tracking for monitoring
  socket connections, channel joins/leaves, message handling, and connection
  lifecycle events.

  ## Event Naming Convention

  All events follow the pattern: `[:phoenix, :socket_client, component, action]`

  ### Connection Events
  - `[:phoenix, :socket_client, :connection, :start]` - Connection attempt started
  - `[:phoenix, :socket_client, :connection, :stop]` - Connection attempt completed
  - `[:phoenix, :socket_client, :connection, :error]` - Connection attempt failed
  - `[:phoenix, :socket_client, :connection, :established, :start]` - Connection established
  - `[:phoenix, :socket_client, :connection, :established, :stop]` - Connection ended
  - `[:phoenix, :socket_client, :reconnection, :attempt]` - Reconnection attempt

  ### Channel Events
  - `[:phoenix, :socket_client, :channel, :join, :start]` - Channel join started
  - `[:phoenix, :socket_client, :channel, :join, :stop]` - Channel join completed
  - `[:phoenix, :socket_client, :channel, :join, :error]` - Channel join failed
  - `[:phoenix, :socket_client, :channel, :active, :start]` - Channel became active
  - `[:phoenix, :socket_client, :channel, :active, :stop]` - Channel became inactive
  - `[:phoenix, :socket_client, :channel, :leave]` - Channel left
  - `[:phoenix, :socket_client, :channel, :push]` - Message pushed to channel
  - `[:phoenix, :socket_client, :channel, :reply]` - Reply received

  ### Message Events
  - `[:phoenix, :socket_client, :message, :sent]` - Message sent
  - `[:phoenix, :socket_client, :message, :received]` - Message received
  - `[:phoenix, :socket_client, :message, :encode, :start]` - Message encoding started
  - `[:phoenix, :socket_client, :message, :encode, :stop]` - Message encoding completed
  - `[:phoenix, :socket_client, :message, :decode, :start]` - Message decoding started
  - `[:phoenix, :socket_client, :message, :decode, :stop]` - Message decoding completed

  ### System Events
  - `[:phoenix, :socket_client, :heartbeat, :sent]` - Heartbeat sent
  - `[:phoenix, :socket_client, :heartbeat, :timeout]` - Heartbeat timeout
  - `[:phoenix, :socket_client, :error]` - General error

  ## Duration Tracking

  Duration events use the span pattern with start/stop pairs:

  ```elixir
  :telemetry.span([:phoenix, :socket_client, :connection], %{socket_ref: ref, url: url}, fn ->
    # Connection logic here
    {:ok, %{status: :connected}}
  end)
  ```

  This generates:
  - Start event: `[:phoenix, :socket_client, :connection, :start]`
  - Stop event: `[:phoenix, :socket_client, :connection, :stop]`

  ## Configuration

  Configure telemetry behavior in your config:

  ```elixir
  config :phoenix_socket_client, :telemetry,
    enabled: true,
    default_handler: true,
    track_durations: true,
    log_levels: %{
      connection: :info,
      connection_established: :debug,
      channel: :info,
      channel_active: :debug,
      message: :debug,
      error: :error,
      heartbeat: :debug
    }
  ```

  ## Default Handler

  Attach the default handler for Logger integration:

  ```elixir
  Phoenix.SocketClient.Telemetry.attach_default_handler()
  ```

  ## Custom Metrics Integration

  Example with `telemetry_metrics`:

  ```elixir
  defmodule MyApp.Telemetry do
    import Telemetry.Metrics

    def metrics do
      [
        distribution("phoenix.socket_client.connection.duration",
          unit: {:native, :millisecond},
          tags: [:transport, :url]
        ),
        distribution("phoenix.socket_client.channel.join.duration",
          unit: {:native, :millisecond},
          tags: [:topic, :status]
        ),
        counter("phoenix.socket_client.connection.count",
          tags: [:transport]
        )
      ]
    end
  end
  """

  require Logger

  @type event_name :: list(atom())
  @type measurements :: map()
  @type metadata :: map()
  @type span_result :: {:ok, metadata()} | {:error, metadata()}
  @type duration_token ::
          %{
            component: atom(),
            operation: atom(),
            start_time: integer(),
            start_system_time: integer(),
            metadata: metadata()
          }
          | :disabled
  @type duration_context ::
          %{
            component: atom(),
            start_time: integer(),
            operations: %{atom() => integer()},
            metadata: metadata()
          }
          | :disabled

  # Configuration
  @default_config %{
    enabled: true,
    default_handler: false,
    track_durations: true,
    track_memory_usage: true,
    track_message_sizes: true,
    sampler_rate: 1.0,
    max_events_per_second: 1000,
    event_buffer_size: 10000,
    log_levels: %{
      connection: :info,
      connection_established: :debug,
      channel: :info,
      channel_active: :debug,
      message: :debug,
      error: :error,
      heartbeat: :debug,
      optimization: :debug
    },
    filters: %{
      # Filter out high-frequency events that might create noise
      exclude_heartbeats: false,
      exclude_message_sends: false,
      exclude_system_metrics: false,
      # in milliseconds
      min_duration_threshold: 0
    }
  }

  @doc """
  Gets the current telemetry configuration.
  """
  @spec config() :: map()
  def config do
    stored_config = Application.get_env(:phoenix_socket_client, :telemetry, %{})
    Map.merge(@default_config, stored_config)
  end

  @doc """
  Checks if telemetry is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config().enabled
  end

  @doc """
  Updates telemetry configuration.
  """
  @spec update_config(map()) :: :ok
  def update_config(new_config) when is_map(new_config) do
    current_config = config()
    updated_config = Map.merge(current_config, new_config)
    Application.put_env(:phoenix_socket_client, :telemetry, updated_config)
    :ok
  end

  @doc """
  Resets telemetry configuration to defaults.
  """
  @spec reset_config() :: :ok
  def reset_config do
    Application.put_env(:phoenix_socket_client, :telemetry, @default_config)
    :ok
  end

  @doc """
  Gets a specific configuration value.
  """
  @spec get_config(atom()) :: any()
  def get_config(key) when is_atom(key) do
    config()[key]
  end

  @doc """
  Checks if duration tracking is enabled.
  """
  @spec track_durations?() :: boolean()
  def track_durations? do
    enabled?() and config().track_durations
  end

  @doc """
  Checks if memory usage tracking is enabled.
  """
  @spec track_memory_usage?() :: boolean()
  def track_memory_usage? do
    enabled?() and config().track_memory_usage
  end

  @doc """
  Checks if message size tracking is enabled.
  """
  @spec track_message_sizes?() :: boolean()
  def track_message_sizes? do
    enabled?() and config().track_message_sizes
  end

  @doc """
  Gets the current sampler rate.
  """
  @spec sampler_rate() :: float()
  def sampler_rate do
    config().sampler_rate
  end

  @doc """
  Checks if an event should be sampled based on the sampler rate.
  """
  @spec should_sample?() :: boolean()
  def should_sample? do
    rate = sampler_rate()

    cond do
      rate >= 1.0 -> true
      rate <= 0.0 -> false
      true -> :rand.uniform() <= rate
    end
  end

  @doc """
  Checks if an event passes the configured filters.
  """
  @spec passes_filters?(event_name(), measurements()) :: boolean()
  def passes_filters?(event_name, measurements \\ %{}) do
    filters = config().filters

    # Check minimum duration threshold first
    if measurements[:duration] do
      # Convert from nanoseconds to milliseconds
      duration_ms = measurements[:duration] / 1_000_000

      if duration_ms < filters.min_duration_threshold do
        false
      else
        check_event_type_filters(event_name, filters)
      end
    else
      check_event_type_filters(event_name, filters)
    end
  end

  defp check_event_type_filters(event_name, filters) do
    case event_name do
      [:phoenix, :socket_client, :heartbeat | _] -> not filters.exclude_heartbeats
      [:phoenix, :socket_client, :message, :send | _] -> not filters.exclude_message_sends
      [:phoenix, :socket_client, :optimization, :system | _] -> not filters.exclude_system_metrics
      _ -> true
    end
  end

  @doc """
  Emits a telemetry event if telemetry is enabled and passes sampling/filters.
  """
  @spec emit_event(event_name(), measurements(), metadata()) :: :ok
  def emit_event(event_name, measurements \\ %{}, metadata \\ %{}) do
    if enabled?() and should_sample?() and passes_filters?(event_name, measurements) do
      :telemetry.execute(event_name, measurements, metadata)
    else
      :ok
    end
  end

  # Span-based duration tracking

  @doc """
  Executes a function with telemetry span for duration tracking.

  This is the preferred way to track durations as it ensures proper
  start/stop event pairing and handles errors gracefully.

  ## Example

      Phoenix.SocketClient.Telemetry.span(
        [:phoenix, :socket_client, :connection],
        %{socket_ref: ref, url: url},
        fn -> connect_to_server() end
      )
  """
  @spec span(event_name(), metadata(), (-> span_result())) :: span_result()
  def span(event_name, metadata, fun)
      when is_list(event_name) and is_map(metadata) and is_function(fun, 0) do
    if enabled?() and track_durations?() and should_sample?() and passes_filters?(event_name) do
      # We need to return the function result, not just :ok like :telemetry.span does
      start_time = System.monotonic_time()
      start_system_time = System.system_time()

      emit_event(
        event_name ++ [:start],
        %{system_time: start_system_time},
        metadata
      )

      try do
        result = fun.()
        end_time = System.monotonic_time()
        duration = end_time - start_time

        emit_event(
          event_name ++ [:stop],
          %{duration: duration},
          metadata
        )

        result
      rescue
        exception ->
          end_time = System.monotonic_time()
          duration = end_time - start_time

          emit_event(
            event_name ++ [:exception],
            %{duration: duration},
            Map.merge(metadata, %{kind: :rescue, exception: exception, stacktrace: __STACKTRACE__})
          )

          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          end_time = System.monotonic_time()
          duration = end_time - start_time

          emit_event(
            event_name ++ [:exception],
            %{duration: duration},
            Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      # Execute function without telemetry if disabled or filtered
      fun.()
    end
  end

  # State Management for Duration Tracking

  @doc """
  Starts tracking duration for a specific operation.

  Returns a tracking token that should be used with `stop_duration/3`.
  """
  @spec start_duration(atom(), atom(), metadata()) :: duration_token()
  def start_duration(component, operation, metadata \\ %{})
      when is_atom(component) and is_atom(operation) and is_map(metadata) do
    if enabled?() and config().track_durations do
      token = %{
        component: component,
        operation: operation,
        start_time: System.monotonic_time(),
        start_system_time: System.system_time(),
        metadata: metadata
      }

      emit_event(
        [:phoenix, :socket_client, component, operation, :start],
        %{system_time: token.start_system_time},
        metadata
      )

      token
    else
      :disabled
    end
  end

  @doc """
  Stops duration tracking for a specific operation.

  Emits the stop event with duration measurements.
  """
  @spec stop_duration(duration_token(), map()) :: :ok
  def stop_duration(token, additional_metadata \\ %{})

  def stop_duration(:disabled, _additional_metadata), do: :ok

  def stop_duration(token, additional_metadata) when is_map(token) do
    if enabled?() and config().track_durations do
      end_time = System.monotonic_time()
      duration = end_time - token.start_time

      measurements = %{
        duration: duration,
        system_time: System.system_time()
      }

      metadata = Map.merge(token.metadata, additional_metadata)

      emit_event(
        [:phoenix, :socket_client, token.component, token.operation, :stop],
        measurements,
        metadata
      )
    else
      :ok
    end
  end

  @doc """
  Measures execution time of a function and emits start/stop events.

  This is similar to `span/3` but provides more explicit control over
  the event names and metadata structure.
  """
  @spec measure_duration(atom(), atom(), metadata(), (-> result)) :: result
        when result: any()
  def measure_duration(component, operation, metadata \\ %{}, function)
      when is_atom(component) and is_atom(operation) and is_map(metadata) and
             is_function(function, 0) do
    token = start_duration(component, operation, metadata)

    try do
      result = function.()
      stop_duration(token, %{status: :success})
      result
    rescue
      error ->
        stop_duration(token, %{status: :error, error: inspect(error)})
        reraise error, __STACKTRACE__
    catch
      kind, value ->
        stop_duration(token, %{status: :catch, kind: kind, value: inspect(value)})
        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  @doc """
  Creates a duration measurement context for complex operations.

  Returns a context that can be used to measure multiple sub-operations.
  """
  @spec create_duration_context(atom(), metadata()) :: duration_context()
  def create_duration_context(component, metadata \\ %{})
      when is_atom(component) and is_map(metadata) do
    if enabled?() and config().track_durations do
      %{
        component: component,
        start_time: System.monotonic_time(),
        operations: %{},
        metadata: metadata
      }
    else
      :disabled
    end
  end

  @doc """
  Measures a sub-operation within a duration context.
  """
  @spec measure_sub_operation(duration_context(), atom(), (-> result)) :: result
        when result: any() do
    measure_sub_operation(context, nil, function)
  end

  def measure_sub_operation(:disabled, _operation, function), do: function.()

  def measure_sub_operation(context, operation, function)
      when is_map(context) and is_atom(operation) do
    start_time = System.monotonic_time()

    try do
      result = function.()
      end_time = System.monotonic_time()
      duration = end_time - start_time

      # Store sub-operation duration
      _updated_operations = Map.put(context.operations, operation, duration)

      # Emit sub-operation event
      emit_event(
        [:phoenix, :socket_client, context.component, operation, :complete],
        %{duration: duration},
        context.metadata
      )

      # Return the result with the updated context stored in a process dictionary or similar
      # For now, we'll update the context via a side effect that can be retrieved later
      # In a real implementation, this would need a different approach
      result
    rescue
      error ->
        end_time = System.monotonic_time()
        duration = end_time - start_time

        emit_event(
          [:phoenix, :socket_client, context.component, operation, :error],
          %{duration: duration},
          Map.merge(context.metadata, %{error: inspect(error)})
        )

        reraise error, __STACKTRACE__
    catch
      kind, value ->
        end_time = System.monotonic_time()
        duration = end_time - start_time

        emit_event(
          [:phoenix, :socket_client, context.component, operation, :catch],
          %{duration: duration},
          Map.merge(context.metadata, %{kind: kind, value: inspect(value)})
        )

        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  @doc """
  Completes a duration context and emits summary events.
  """
  @spec complete_duration_context(duration_context(), metadata()) :: :ok
  def complete_duration_context(:disabled, _additional_metadata), do: :ok

  def complete_duration_context(context, additional_metadata) when is_map(context) do
    if enabled?() and config().track_durations do
      end_time = System.monotonic_time()
      total_duration = end_time - context.start_time

      measurements = %{
        total_duration: total_duration,
        operation_count: map_size(context.operations),
        system_time: System.system_time()
      }

      # Add operation-specific measurements
      operation_measurements =
        Enum.reduce(context.operations, measurements, fn {op, duration}, acc ->
          Map.put(acc, "#{op}_duration", duration)
        end)

      metadata = Map.merge(context.metadata, additional_metadata)

      emit_event(
        [:phoenix, :socket_client, context.component, :context_complete],
        operation_measurements,
        metadata
      )
    else
      :ok
    end
  end

  # Connection Events

  @doc """
  Emits connection start event.
  """
  @spec connection_start(metadata()) :: :ok
  def connection_start(metadata) do
    emit_event(
      [:phoenix, :socket_client, :connection, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits connection stop event.
  """
  @spec connection_stop(metadata()) :: :ok
  def connection_stop(metadata) do
    emit_event(
      [:phoenix, :socket_client, :connection, :stop],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits connection error event.
  """
  @spec connection_error(metadata()) :: :ok
  def connection_error(metadata) do
    emit_event(
      [:phoenix, :socket_client, :connection, :error],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits connection established start event.
  """
  @spec connection_established_start(metadata()) :: :ok
  def connection_established_start(metadata) do
    emit_event(
      [:phoenix, :socket_client, :connection, :established, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits connection established stop event.
  """
  @spec connection_established_stop(metadata()) :: :ok
  def connection_established_stop(metadata) do
    emit_event(
      [:phoenix, :socket_client, :connection, :established, :stop],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits reconnection attempt event.
  """
  @spec reconnection_attempt(metadata()) :: :ok
  def reconnection_attempt(metadata) do
    emit_event(
      [:phoenix, :socket_client, :reconnection, :attempt],
      %{system_time: System.system_time()},
      metadata
    )
  end

  # Channel Events

  @doc """
  Emits channel join start event.
  """
  @spec channel_join_start(metadata()) :: :ok
  def channel_join_start(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :join, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel join stop event.
  """
  @spec channel_join_stop(metadata()) :: :ok
  def channel_join_stop(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :join, :stop],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel join error event.
  """
  @spec channel_join_error(metadata()) :: :ok
  def channel_join_error(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :join, :error],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel active start event.
  """
  @spec channel_active_start(metadata()) :: :ok
  def channel_active_start(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :active, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel active stop event.
  """
  @spec channel_active_stop(metadata()) :: :ok
  def channel_active_stop(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :active, :stop],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel leave event.
  """
  @spec channel_leave(metadata()) :: :ok
  def channel_leave(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :leave],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel push event.
  """
  @spec channel_push(metadata()) :: :ok
  def channel_push(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :push],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel reply event.
  """
  @spec channel_reply(metadata()) :: :ok
  def channel_reply(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :reply],
      %{system_time: System.system_time()},
      metadata
    )
  end

  # Message Events

  @doc """
  Emits message sent event.
  """
  @spec message_sent(metadata()) :: :ok
  def message_sent(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :sent],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits message received event.
  """
  @spec message_received(metadata()) :: :ok
  def message_received(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :received],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits message encode start event.
  """
  @spec message_encode_start(metadata()) :: :ok
  def message_encode_start(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :encode, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits message encode stop event.
  """
  @spec message_encode_stop(metadata()) :: :ok
  def message_encode_stop(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :encode, :stop],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits message decode start event.
  """
  @spec message_decode_start(metadata()) :: :ok
  def message_decode_start(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :decode, :start],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits message decode stop event.
  """
  @spec message_decode_stop(metadata()) :: :ok
  def message_decode_stop(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :decode, :stop],
      %{system_time: System.system_time()},
      metadata
    )
  end

  # System Events

  @doc """
  Emits heartbeat sent event.
  """
  @spec heartbeat_sent(metadata()) :: :ok
  def heartbeat_sent(metadata) do
    emit_event(
      [:phoenix, :socket_client, :heartbeat, :sent],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits heartbeat timeout event.
  """
  @spec heartbeat_timeout(metadata()) :: :ok
  def heartbeat_timeout(metadata) do
    emit_event(
      [:phoenix, :socket_client, :heartbeat, :timeout],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits general error event.
  """
  @spec error(metadata()) :: :ok
  def error(metadata) do
    emit_event(
      [:phoenix, :socket_client, :error],
      %{system_time: System.system_time()},
      metadata
    )
  end

  # Optimization Events

  @doc """
  Emits optimization-related event.
  """
  @spec optimization(atom(), metadata()) :: :ok
  def optimization(optimization_type, metadata) do
    emit_event(
      [:phoenix, :socket_client, :optimization, optimization_type],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits cache hit optimization event.
  """
  @spec optimization_cache_hit(metadata()) :: :ok
  def optimization_cache_hit(metadata) do
    emit_event(
      [:phoenix, :socket_client, :optimization, :cache, :hit],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits cache miss optimization event.
  """
  @spec optimization_cache_miss(metadata()) :: :ok
  def optimization_cache_miss(metadata) do
    emit_event(
      [:phoenix, :socket_client, :optimization, :cache, :miss],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits binary pool hit optimization event.
  """
  @spec optimization_binary_pool_hit(metadata()) :: :ok
  def optimization_binary_pool_hit(metadata) do
    emit_event(
      [:phoenix, :socket_client, :optimization, :binary_pool, :hit],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits process hibernated optimization event.
  """
  @spec optimization_process_hibernated(metadata()) :: :ok
  def optimization_process_hibernated(metadata) do
    emit_event(
      [:phoenix, :socket_client, :optimization, :hibernation, :process_hibernated],
      %{system_time: System.system_time()},
      metadata
    )
  end

  # Debug Events

  @doc """
  Emits debug-level event.
  """
  @spec debug(metadata()) :: :ok
  def debug(metadata) do
    emit_event(
      [:phoenix, :socket_client, :debug],
      %{system_time: System.system_time()},
      metadata
    )
  end

  # Additional helper functions needed by tests

  @doc """
  Emits message send event.
  """
  @spec message_send(metadata()) :: :ok
  def message_send(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :send],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits message receive event.
  """
  @spec message_receive(metadata()) :: :ok
  def message_receive(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :receive],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits message encoded event.
  """
  @spec message_encoded(metadata()) :: :ok
  def message_encoded(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :encode],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits message decoded event.
  """
  @spec message_decoded(metadata()) :: :ok
  def message_decoded(metadata) do
    emit_event(
      [:phoenix, :socket_client, :message, :decode],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel active event.
  """
  @spec channel_active(metadata()) :: :ok
  def channel_active(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :active],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel left event.
  """
  @spec channel_left(metadata()) :: :ok
  def channel_left(metadata) do
    emit_event(
      [:phoenix, :socket_client, :channel, :leave],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc """
  Emits channel status changed event.
  """
  @spec channel_status_changed(pid(), String.t(), atom(), atom()) :: :ok
  def channel_status_changed(channel_pid, topic, old_status, new_status) do
    emit_event(
      [:phoenix, :socket_client, :channel, :status_changed],
      %{system_time: System.system_time()},
      %{
        channel_pid: channel_pid,
        topic: topic,
        old_status: old_status,
        new_status: new_status
      }
    )
  end

  @doc """
  Emits channel join duration event.
  """
  @spec channel_join_duration(pid(), String.t(), non_neg_integer()) :: :ok
  def channel_join_duration(channel_pid, topic, duration) do
    emit_event(
      [:phoenix, :socket_client, :channel, :join_duration],
      %{duration: duration, system_time: System.system_time()},
      %{channel_pid: channel_pid, topic: topic}
    )
  end

  @doc """
  Emits channel leave duration event.
  """
  @spec channel_leave_duration(pid(), String.t(), non_neg_integer()) :: :ok
  def channel_leave_duration(channel_pid, topic, duration) do
    emit_event(
      [:phoenix, :socket_client, :channel, :leave_duration],
      %{duration: duration, system_time: System.system_time()},
      %{channel_pid: channel_pid, topic: topic}
    )
  end

  @doc """
  Legacy execute function for backward compatibility.
  """
  @spec execute(event_name(), measurements(), metadata()) :: :ok
  def execute(event_name, measurements, metadata) do
    emit_event(event_name, measurements, metadata)
  end

  # Legacy compatibility functions (delegating to new system)

  @doc """
  Legacy: Emits socket connection event.
  """
  @spec socket_connected(pid(), String.t(), metadata()) :: :ok
  def socket_connected(pid, url, metadata \\ %{}) do
    connection_stop(Map.merge(metadata, %{pid: pid, url: url}))
  end

  @doc """
  Legacy: Emits socket disconnection event.
  """
  @spec socket_disconnected(pid(), String.t(), atom(), metadata()) :: :ok
  def socket_disconnected(pid, url, reason, metadata \\ %{}) do
    connection_established_stop(Map.merge(metadata, %{pid: pid, url: url, reason: reason}))
  end

  @doc """
  Legacy: Emits socket connection attempt event.
  """
  @spec socket_connecting(pid(), String.t(), metadata()) :: :ok
  def socket_connecting(pid, url, metadata \\ %{}) do
    connection_start(Map.merge(metadata, %{pid: pid, url: url}))
  end

  @doc """
  Legacy: Emits socket connection error event.
  """
  @spec socket_connection_error(pid(), String.t(), any(), metadata()) :: :ok
  def socket_connection_error(pid, url, error, metadata \\ %{}) do
    connection_error(Map.merge(metadata, %{pid: pid, url: url, error: error}))
  end

  @doc """
  Legacy: Emits channel join event.
  """
  @spec channel_joined(pid(), String.t(), pid(), map(), metadata()) :: :ok
  def channel_joined(pid, topic, channel_pid, response, metadata \\ %{}) do
    channel_join_stop(
      Map.merge(metadata, %{
        pid: pid,
        topic: topic,
        channel_pid: channel_pid,
        response: response,
        status: :ok
      })
    )
  end

  @doc """
  Legacy: Emits channel join error event.
  """
  @spec channel_join_error(pid(), String.t(), any(), metadata()) :: :ok
  def channel_join_error(pid, topic, error, metadata \\ %{}) do
    channel_join_error(
      Map.merge(metadata, %{pid: pid, topic: topic, error: error, status: :error})
    )
  end

  @doc """
  Legacy: Emits channel leave event.
  """
  @spec channel_left(pid(), String.t(), atom(), metadata()) :: :ok
  def channel_left(pid, topic, reason, metadata \\ %{}) do
    channel_leave(Map.merge(metadata, %{pid: pid, topic: topic, reason: reason}))
  end

  @doc """
  Legacy: Emits message sent event.
  """
  @spec message_sent(pid(), String.t(), String.t(), map(), metadata()) :: :ok
  def message_sent(pid, topic, event, payload, metadata \\ %{}) do
    message_sent(
      Map.merge(metadata, %{
        pid: pid,
        topic: topic,
        event: event,
        payload: payload
      })
    )
  end

  @doc """
  Legacy: Emits message received event.
  """
  @spec message_received(pid(), String.t(), String.t(), map(), metadata()) :: :ok
  def message_received(pid, topic, event, payload, metadata \\ %{}) do
    message_received(
      Map.merge(metadata, %{
        pid: pid,
        topic: topic,
        event: event,
        payload: payload
      })
    )
  end

  @doc """
  Legacy: Emits heartbeat event.
  """
  @spec heartbeat_sent(pid(), String.t(), metadata()) :: :ok
  def heartbeat_sent(pid, url, metadata \\ %{}) do
    heartbeat_sent(Map.merge(metadata, %{pid: pid, url: url}))
  end

  @doc """
  Legacy: Emits reconnection attempt event.
  """
  @spec reconnecting(pid(), String.t(), integer(), metadata()) :: :ok
  def reconnecting(pid, url, attempt, metadata \\ %{}) do
    reconnection_attempt(Map.merge(metadata, %{pid: pid, url: url, attempt: attempt}))
  end

  # Default Handler

  @doc """
  Attaches the default telemetry handler that converts events to Logger calls.

  The handler respects the configured log levels and formats duration
  measurements in human-readable format.

  ## Example

      Phoenix.SocketClient.Telemetry.attach_default_handler()

  You can also provide custom configuration:

      Phoenix.SocketClient.Telemetry.attach_default_handler(
        log_levels: %{connection: :debug, error: :warn}
      )
  """
  @spec attach_default_handler(keyword()) :: :ok
  def attach_default_handler(opts \\ []) do
    if Keyword.get(opts, :enabled, config().default_handler) do
      handler_id = "phoenix-socket-client-default-handler"

      events = [
        # Connection events
        [:phoenix, :socket_client, :connection, :start],
        [:phoenix, :socket_client, :connection, :stop],
        [:phoenix, :socket_client, :connection, :error],
        [:phoenix, :socket_client, :connection, :established, :start],
        [:phoenix, :socket_client, :connection, :established, :stop],
        [:phoenix, :socket_client, :reconnection, :attempt],

        # Channel events
        [:phoenix, :socket_client, :channel, :join, :start],
        [:phoenix, :socket_client, :channel, :join, :stop],
        [:phoenix, :socket_client, :channel, :join, :error],
        [:phoenix, :socket_client, :channel, :active, :start],
        [:phoenix, :socket_client, :channel, :active, :stop],
        [:phoenix, :socket_client, :channel, :leave],
        [:phoenix, :socket_client, :channel, :push],
        [:phoenix, :socket_client, :channel, :reply],

        # Message events
        [:phoenix, :socket_client, :message, :sent],
        [:phoenix, :socket_client, :message, :received],
        [:phoenix, :socket_client, :message, :encode, :start],
        [:phoenix, :socket_client, :message, :encode, :stop],
        [:phoenix, :socket_client, :message, :decode, :start],
        [:phoenix, :socket_client, :message, :decode, :stop],

        # System events
        [:phoenix, :socket_client, :heartbeat, :sent],
        [:phoenix, :socket_client, :heartbeat, :timeout],
        [:phoenix, :socket_client, :error],

        # Optimization events
        [:phoenix, :socket_client, :optimization]
      ]

      log_levels = Keyword.get(opts, :log_levels, config().log_levels)

      :telemetry.attach_many(
        handler_id,
        events,
        &default_handler/4,
        %{log_levels: log_levels}
      )

      :ok
    else
      :ok
    end
  end

  @doc """
  Detaches the default telemetry handler.
  """
  @spec detach_default_handler() :: :ok
  def detach_default_handler do
    :telemetry.detach("phoenix-socket-client-default-handler")
  end

  @doc """
  Attaches a debug handler that prints all telemetry events.

  Useful for development and debugging.
  """
  @spec attach_debug_handler() :: :ok
  def attach_debug_handler do
    :telemetry.attach_many(
      "phoenix-socket-client-debug",
      [
        [:phoenix, :socket_client, :connection, :start],
        [:phoenix, :socket_client, :connection, :stop],
        [:phoenix, :socket_client, :connection, :error],
        [:phoenix, :socket_client, :connection, :established, :start],
        [:phoenix, :socket_client, :connection, :established, :stop],
        [:phoenix, :socket_client, :reconnection, :attempt],
        [:phoenix, :socket_client, :channel, :join, :start],
        [:phoenix, :socket_client, :channel, :join, :stop],
        [:phoenix, :socket_client, :channel, :join, :error],
        [:phoenix, :socket_client, :channel, :active, :start],
        [:phoenix, :socket_client, :channel, :active, :stop],
        [:phoenix, :socket_client, :channel, :leave],
        [:phoenix, :socket_client, :channel, :push],
        [:phoenix, :socket_client, :channel, :reply],
        [:phoenix, :socket_client, :message, :sent],
        [:phoenix, :socket_client, :message, :received],
        [:phoenix, :socket_client, :message, :encode, :start],
        [:phoenix, :socket_client, :message, :encode, :stop],
        [:phoenix, :socket_client, :message, :decode, :start],
        [:phoenix, :socket_client, :message, :decode, :stop],
        [:phoenix, :socket_client, :heartbeat, :sent],
        [:phoenix, :socket_client, :heartbeat, :timeout],
        [:phoenix, :socket_client, :error],
        [:phoenix, :socket_client, :optimization]
      ],
      &debug_handler/4,
      %{}
    )
  end

  @doc """
  Detaches the debug handler.
  """
  @spec detach_debug_handler() :: :ok
  def detach_debug_handler do
    :telemetry.detach("phoenix-socket-client-debug")
  end

  # Private functions

  defp default_handler(event_name, measurements, metadata, %{log_levels: log_levels}) do
    case get_log_level(event_name, log_levels) do
      nil ->
        # No logging configured for this event
        :ok

      level ->
        message = format_event_message(event_name, measurements, metadata)
        Logger.log(level, message)
    end
  end

  defp debug_handler(event_name, measurements, metadata, _config) do
    # Debug telemetry events - can be enabled via Logger level
    require Logger

    Logger.debug(fn ->
      "[Phoenix.SocketClient] Telemetry: #{inspect(event_name)} - #{inspect(measurements)} - #{inspect(metadata)}"
    end)
  end

  defp get_log_level(event_name, log_levels) do
    case event_name do
      [:phoenix, :socket_client, :connection, :established, _action] ->
        log_levels[:connection_established] || log_levels[:connection]

      [:phoenix, :socket_client, :connection, _action] ->
        log_levels[:connection]

      [:phoenix, :socket_client, :channel, :active, _action] ->
        log_levels[:channel_active] || log_levels[:channel]

      [:phoenix, :socket_client, :channel, _action] ->
        log_levels[:channel]

      [:phoenix, :socket_client, :message, _action] ->
        log_levels[:message]

      [:phoenix, :socket_client, :heartbeat, _action] ->
        log_levels[:heartbeat]

      [:phoenix, :socket_client, :error] ->
        log_levels[:error]

      [:phoenix, :socket_client, :optimization, _type] ->
        log_levels[:optimization]

      _ ->
        # Default fallback
        log_levels[:connection]
    end
  end

  defp format_event_message(event_name, measurements, metadata) do
    action = get_action_from_event(event_name)
    component = get_component_from_event(event_name)

    base_message = "Phoenix.SocketClient #{component} #{action}"

    # Add duration if available
    message =
      case measurements do
        %{duration: duration} ->
          duration_ms = System.convert_time_unit(duration, :native, :millisecond)
          "#{base_message} duration=#{duration_ms}ms"

        _ ->
          base_message
      end

    # Add key metadata
    metadata_parts =
      []
      |> maybe_add_metadata_part(metadata, :socket_ref)
      |> maybe_add_metadata_part(metadata, :topic)
      |> maybe_add_metadata_part(metadata, :url)
      |> maybe_add_metadata_part(metadata, :status)
      |> maybe_add_metadata_part(metadata, :reason)
      |> maybe_add_metadata_part(metadata, :error)

    if length(metadata_parts) > 0 do
      "#{message} #{Enum.join(metadata_parts, " ")}"
    else
      message
    end
  end

  defp get_action_from_event(event_name) do
    case event_name do
      [:phoenix, :socket_client, :connection | rest] -> connection_action(rest)
      [:phoenix, :socket_client, :reconnection, :attempt] -> "reconnecting"
      [:phoenix, :socket_client, :channel | rest] -> channel_action(rest)
      [:phoenix, :socket_client, :message | rest] -> message_action(rest)
      [:phoenix, :socket_client, :heartbeat | rest] -> heartbeat_action(rest)
      [:phoenix, :socket_client, :error] -> "error occurred"
      [:phoenix, :socket_client, :optimization, _type] -> "optimization event"
      _ -> "unknown event"
    end
  end

  defp connection_action([:start]), do: "connecting"
  defp connection_action([:stop]), do: "connected"
  defp connection_action([:error]), do: "connection failed"
  defp connection_action([:established, :start]), do: "connection established"
  defp connection_action([:established, :stop]), do: "connection ended"
  defp connection_action(_), do: "connection event"

  defp channel_action([:join, :start]), do: "joining channel"
  defp channel_action([:join, :stop]), do: "joined channel"
  defp channel_action([:join, :error]), do: "channel join failed"
  defp channel_action([:active, :start]), do: "channel active"
  defp channel_action([:active, :stop]), do: "channel inactive"
  defp channel_action([:leave]), do: "left channel"
  defp channel_action([:push]), do: "pushed message"
  defp channel_action([:reply]), do: "received reply"
  defp channel_action(_), do: "channel event"

  defp message_action([:sent]), do: "sent message"
  defp message_action([:received]), do: "received message"
  defp message_action([:encode, :start]), do: "encoding message"
  defp message_action([:encode, :stop]), do: "encoded message"
  defp message_action([:decode, :start]), do: "decoding message"
  defp message_action([:decode, :stop]), do: "decoded message"
  defp message_action(_), do: "message event"

  defp heartbeat_action([:sent]), do: "heartbeat sent"
  defp heartbeat_action([:timeout]), do: "heartbeat timeout"
  defp heartbeat_action(_), do: "heartbeat event"

  defp get_component_from_event(event_name) do
    case event_name do
      [:phoenix, :socket_client, :connection, _] -> "Connection"
      [:phoenix, :socket_client, :reconnection, _] -> "Reconnection"
      [:phoenix, :socket_client, :channel, _] -> "Channel"
      [:phoenix, :socket_client, :message, _] -> "Message"
      [:phoenix, :socket_client, :heartbeat, _] -> "Heartbeat"
      [:phoenix, :socket_client, :error] -> "Error"
      [:phoenix, :socket_client, :optimization, _] -> "Optimization"
      _ -> "Unknown"
    end
  end

  defp maybe_add_metadata_part(parts, metadata, key) do
    case Map.get(metadata, key) do
      nil -> parts
      value -> ["#{key}=#{inspect(value)}" | parts]
    end
  end
end
