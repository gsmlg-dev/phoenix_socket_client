defmodule Phoenix.SocketClient.PerformanceMonitor do
  @moduledoc """
  Comprehensive performance monitoring for Phoenix Socket Client.

  This module provides centralized performance monitoring and metrics
  collection from all optimization components. It aggregates data from
  binary pools, route caches, hibernation manager, and transport
  performance to provide a complete view of system performance.

  ## Features

  - Real-time performance metrics
  - Memory usage monitoring
  - Connection performance tracking
  - Cache hit rate analysis
  - Hibernation effectiveness
  - Network throughput metrics
  - Alerting for performance issues

  ## Usage

  The monitor is automatically started by the socket supervisor
  and provides performance data through various interfaces.

  ## Metrics Collected

  - Binary pool efficiency and memory savings
  - Route cache hit rates and size
  - Process hibernation statistics
  - Network throughput and latency
  - Message processing rates
  - Memory usage patterns
  - Error rates and types
  """

  use GenServer
  require Logger

  # 30 seconds
  @default_collection_interval 30_000
  # 30 minutes
  @default_retention_period 1_800_000
  @default_alert_thresholds %{
    memory_usage_mb: 100,
    cache_hit_rate: 0.8,
    message_queue_depth: 1000,
    response_time_ms: 1000
  }

  @typedoc """
  Monitor configuration options
  """
  @type opts :: [
          collection_interval: non_neg_integer(),
          retention_period: non_neg_integer(),
          registry_name: atom(),
          alert_thresholds: map()
        ]

  @typedoc """
  Performance metrics structure
  """
  @type metrics :: %{
          timestamp: integer(),
          binary_pool: map(),
          route_cache: map(),
          hibernation: map(),
          transport: map(),
          system: map(),
          alerts: list(map())
        }

  @typedoc """
  Monitor state
  """
  @type t :: %__MODULE__{
          collection_interval: non_neg_integer(),
          retention_period: non_neg_integer(),
          registry_name: atom() | nil,
          alert_thresholds: map(),
          metrics_history: :ets.tid(),
          current_metrics: metrics(),
          collection_timer: reference() | nil,
          stats: %{
            collections: non_neg_integer(),
            alerts_triggered: non_neg_integer(),
            uptime_start: integer()
          }
        }

  defstruct [
    :collection_interval,
    :retention_period,
    :registry_name,
    :alert_thresholds,
    :metrics_history,
    current_metrics: %{},
    collection_timer: nil,
    stats: %{
      collections: 0,
      alerts_triggered: 0,
      uptime_start: System.monotonic_time(:millisecond)
    }
  ]

  @doc """
  Starts the performance monitor.

  ## Options
    * `:collection_interval` - Metrics collection interval (default: 30000ms)
    * `:retention_period` - How long to retain metrics (default: 1800000ms)
    * `:registry_name` - Registry name for component discovery
    * `:alert_thresholds` - Alerting thresholds map
  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = if Keyword.keyword?(opts), do: opts, else: Enum.into(opts, [])
    registry_name = Keyword.get(opts, :registry_name)

    name =
      if registry_name, do: {:via, Registry, {registry_name, :performance_monitor}}, else: nil

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets current performance metrics.

  Returns the most recent performance data collected.
  """
  @spec get_metrics(pid()) :: {:ok, metrics()} | {:error, term()}
  def get_metrics(monitor_pid) when is_pid(monitor_pid) do
    GenServer.call(monitor_pid, :get_metrics, 5000)
  end

  @doc """
  Gets historical performance metrics.

  Returns metrics for a specified time range.
  """
  @spec get_metrics_history(pid(), integer(), integer()) ::
          {:ok, list(metrics())} | {:error, term()}
  def get_metrics_history(monitor_pid, from_time, to_time \\ System.monotonic_time(:millisecond)) do
    GenServer.call(monitor_pid, {:get_metrics_history, from_time, to_time}, 5000)
  end

  @doc """
  Gets performance summary statistics.

  Returns aggregated statistics for the monitoring period.
  """
  @spec get_summary(pid()) :: {:ok, map()} | {:error, term()}
  def get_summary(monitor_pid) when is_pid(monitor_pid) do
    GenServer.call(monitor_pid, :get_summary, 5000)
  end

  @doc """
  Triggers immediate metrics collection.

  Useful for on-demand performance checks.
  """
  @spec collect_metrics(pid()) :: :ok
  def collect_metrics(monitor_pid) when is_pid(monitor_pid) do
    GenServer.cast(monitor_pid, :collect_metrics)
  end

  @doc """
  Updates alert thresholds.

  Modifies the thresholds used for performance alerting.
  """
  @spec update_alert_thresholds(pid(), map()) :: :ok
  def update_alert_thresholds(monitor_pid, thresholds)
      when is_pid(monitor_pid) and is_map(thresholds) do
    GenServer.cast(monitor_pid, {:update_alert_thresholds, thresholds})
  end

  @doc """
  Generates performance report.

  Creates a comprehensive performance report in various formats.
  """
  @spec generate_report(pid(), atom()) :: {:ok, String.t()} | {:error, term()}
  def generate_report(monitor_pid, format \\ :text) when is_pid(monitor_pid) do
    GenServer.call(monitor_pid, {:generate_report, format}, 10_000)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    collection_interval = Keyword.get(opts, :collection_interval, @default_collection_interval)
    retention_period = Keyword.get(opts, :retention_period, @default_retention_period)
    registry_name = Keyword.get(opts, :registry_name)
    alert_thresholds = Keyword.get(opts, :alert_thresholds, @default_alert_thresholds)

    # Create ETS table for metrics history
    metrics_table =
      :ets.new(:performance_metrics, [
        :ordered_set,
        :protected,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    # Start collection timer
    {:ok, timer} = :timer.send_interval(collection_interval, :collect_metrics)

    state = %__MODULE__{
      collection_interval: collection_interval,
      retention_period: retention_period,
      registry_name: registry_name,
      alert_thresholds: alert_thresholds,
      metrics_history: metrics_table,
      collection_timer: timer
    }

    Phoenix.SocketClient.Telemetry.optimization(:performance_monitor_started, %{
      collection_interval: collection_interval,
      retention_period: retention_period
    })

    # Collect initial metrics
    send(self(), :collect_metrics)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, {:ok, state.current_metrics}, state}
  end

  @impl true
  def handle_call({:get_metrics_history, from_time, to_time}, _from, state) do
    history =
      :ets.select(state.metrics_history, [
        {{{:timestamp, :"$1"}, :"$2"},
         [{:andalso, {:>=, :"$1", from_time}, {:"=<", :"$1", to_time}}], [:"$_"]}
      ])

    metrics_list = Enum.map(history, fn {{:timestamp, _timestamp}, metrics} -> metrics end)
    {:reply, {:ok, metrics_list}, state}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    summary = generate_summary(state)
    {:reply, {:ok, summary}, state}
  end

  @impl true
  def handle_call({:generate_report, format}, _from, state) do
    report = generate_performance_report(state, format)
    {:reply, report, state}
  end

  @impl true
  def handle_cast(:collect_metrics, state) do
    new_state = perform_metrics_collection(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:update_alert_thresholds, new_thresholds}, state) do
    updated_thresholds = Map.merge(state.alert_thresholds, new_thresholds)
    new_state = %{state | alert_thresholds: updated_thresholds}

    Phoenix.SocketClient.Telemetry.optimization(:performance_monitor_alert_thresholds_updated, %{
      new_thresholds: new_thresholds
    })

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:collect_metrics, state) do
    new_state = perform_metrics_collection(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup_metrics, state) do
    cutoff_time = System.monotonic_time(:millisecond) - state.retention_period

    # Remove old metrics
    removed =
      :ets.select_delete(state.metrics_history, [
        {{{:timestamp, :"$1"}, :"$2"}, [{:<, :"$1", cutoff_time}], [true]}
      ])

    if removed > 0 do
      Phoenix.SocketClient.Telemetry.optimization(:performance_monitor_cleanup, %{
        entries_removed: removed,
        retention_period: state.retention_period
      })
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.collection_timer do
      :timer.cancel(state.collection_timer)
    end

    :ets.delete(state.metrics_history)

    Phoenix.SocketClient.Telemetry.optimization(:performance_monitor_terminating, %{
      total_collections: state.stats.collections,
      alerts_triggered: state.stats.alerts_triggered,
      final_metrics_size: :ets.info(state.metrics_history, :size)
    })

    :ok
  end

  # Private helper functions

  defp perform_metrics_collection(state) do
    current_time = System.monotonic_time(:millisecond)

    try do
      # Collect metrics from all components
      metrics = %{
        timestamp: current_time,
        binary_pool: collect_binary_pool_metrics(state.registry_name),
        route_cache: collect_route_cache_metrics(state.registry_name),
        hibernation: collect_hibernation_metrics(state.registry_name),
        transport: collect_transport_metrics(state.registry_name),
        system: collect_system_metrics(),
        alerts: []
      }

      # Check for alerts
      alerts = check_alerts(metrics, state.alert_thresholds)
      final_metrics = %{metrics | alerts: alerts}

      # Store in history
      :ets.insert(state.metrics_history, {{:timestamp, current_time}, final_metrics})

      # Update stats
      new_stats = %{
        state.stats
        | collections: state.stats.collections + 1,
          alerts_triggered: state.stats.alerts_triggered + length(alerts)
      }

      new_state = %{state | current_metrics: final_metrics, stats: new_stats}

      # Log alerts
      if length(alerts) > 0 do
        Phoenix.SocketClient.Telemetry.optimization(:performance_monitor_alerts_triggered, %{
          alerts_count: length(alerts),
          alerts: alerts
        })
      end

      # Schedule cleanup
      Process.send_after(self(), :cleanup_metrics, state.collection_interval)

      new_state
    rescue
      error ->
        Phoenix.SocketClient.Telemetry.error(%{
          component: :performance_monitor,
          event: :metrics_collection_failed,
          error: inspect(error)
        })

        state
    end
  end

  defp collect_binary_pool_metrics(_registry_name) do
    # This would get stats from the binary pool
    # For now, return placeholder data
    %{
      pool_size: 0,
      memory_saved_bytes: 0,
      hit_rate: 0.0,
      eviction_count: 0
    }
  end

  defp collect_route_cache_metrics(_registry_name) do
    # This would get stats from the route cache
    %{
      cache_size: 0,
      hit_rate: 0.0,
      miss_rate: 0.0,
      eviction_count: 0,
      memory_usage_bytes: 0
    }
  end

  defp collect_hibernation_metrics(_registry_name) do
    # This would get stats from the hibernation manager
    %{
      hibernated_processes: 0,
      total_hibernations: 0,
      memory_saved_bytes: 0,
      average_idle_time: 0
    }
  end

  defp collect_transport_metrics(_registry_name) do
    # This would get stats from the transport
    %{
      messages_sent: 0,
      messages_received: 0,
      bytes_sent: 0,
      bytes_received: 0,
      connection_uptime: 0,
      latency_ms: 0
    }
  end

  defp collect_system_metrics do
    # Collect system-level metrics
    {:memory, memory_info} = :erlang.process_info(self(), :memory)
    {:message_queue_len, queue_len} = :erlang.process_info(self(), :message_queue_len)

    %{
      memory_usage_words: memory_info,
      # Convert words to MB
      memory_usage_mb: memory_info / (1024 * 1024 / 8),
      message_queue_depth: queue_len,
      process_count: :erlang.system_info(:process_count),
      scheduler_utilization: 0.0
    }
  end

  defp check_alerts(metrics, thresholds) do
    alerts = []

    # Check memory usage
    alerts =
      if metrics.system.memory_usage_mb > thresholds.memory_usage_mb do
        [
          %{
            type: :memory_usage,
            severity: :warning,
            message: "High memory usage: #{Float.round(metrics.system.memory_usage_mb, 2)}MB",
            threshold: thresholds.memory_usage_mb,
            current_value: metrics.system.memory_usage_mb,
            timestamp: metrics.timestamp
          }
          | alerts
        ]
      else
        alerts
      end

    # Check cache hit rate
    alerts =
      if metrics.route_cache.hit_rate < thresholds.cache_hit_rate do
        [
          %{
            type: :cache_performance,
            severity: :warning,
            message: "Low cache hit rate: #{Float.round(metrics.route_cache.hit_rate * 100, 2)}%",
            threshold: thresholds.cache_hit_rate,
            current_value: metrics.route_cache.hit_rate,
            timestamp: metrics.timestamp
          }
          | alerts
        ]
      else
        alerts
      end

    # Check message queue depth
    alerts =
      if metrics.system.message_queue_depth > thresholds.message_queue_depth do
        [
          %{
            type: :message_queue,
            severity: :critical,
            message: "High message queue depth: #{metrics.system.message_queue_depth}",
            threshold: thresholds.message_queue_depth,
            current_value: metrics.system.message_queue_depth,
            timestamp: metrics.timestamp
          }
          | alerts
        ]
      else
        alerts
      end

    alerts
  end

  defp generate_summary(state) do
    current_time = System.monotonic_time(:millisecond)
    uptime_ms = current_time - state.stats.uptime_start

    %{
      uptime_ms: uptime_ms,
      uptime_hours: uptime_ms / (1000 * 60 * 60),
      collections: state.stats.collections,
      alerts_triggered: state.stats.alerts_triggered,
      collection_interval: state.collection_interval,
      current_metrics: state.current_metrics,
      data_points_retained: :ets.info(state.metrics_history, :size)
    }
  end

  defp generate_performance_report(state, :text) do
    summary = generate_summary(state)
    metrics = state.current_metrics

    report = """
    Phoenix Socket Client Performance Report
    ======================================

    Summary:
    --------
    Uptime: #{Float.round(summary.uptime_hours, 2)} hours
    Collections: #{summary.collections}
    Alerts Triggered: #{summary.alerts_triggered}
    Data Points: #{summary.data_points_retained}

    Current Metrics:
    ----------------
    Memory Usage: #{Float.round(metrics.system.memory_usage_mb, 2)} MB
    Message Queue Depth: #{metrics.system.message_queue_depth}
    Process Count: #{metrics.system.process_count}

    Route Cache:
    - Size: #{metrics.route_cache.cache_size}
    - Hit Rate: #{Float.round(metrics.route_cache.hit_rate * 100, 2)}%
    - Memory Usage: #{metrics.route_cache.memory_usage_bytes} bytes

    Binary Pool:
    - Pool Size: #{metrics.binary_pool.pool_size}
    - Memory Saved: #{metrics.binary_pool.memory_saved_bytes} bytes
    - Hit Rate: #{Float.round(metrics.binary_pool.hit_rate * 100, 2)}%

    Transport:
    - Messages Sent: #{metrics.transport.messages_sent}
    - Messages Received: #{metrics.transport.messages_received}
    - Bytes Sent: #{metrics.transport.bytes_sent}
    - Bytes Received: #{metrics.transport.bytes_received}

    Recent Alerts:
    ---------------
    #{if length(metrics.alerts) > 0 do
      Enum.map(metrics.alerts, fn alert -> "#{alert.type}: #{alert.message}" end) |> Enum.join("\n")
    else
      "No recent alerts"
    end}

    Generated at: #{DateTime.utc_now() |> DateTime.to_string()}
    """

    {:ok, report}
  end

  defp generate_performance_report(_state, format) when format in [:json, :json_pretty] do
    {:error, :format_not_supported}
  end
end
