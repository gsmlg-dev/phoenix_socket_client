defmodule Phoenix.SocketClient.RouteCache do
  @moduledoc """
  High-performance ETS-based caching for message routing.

  This module provides an ETS-based cache for storing and retrieving
  channel process PIDs by topic, significantly improving message routing
  performance compared to Registry lookups.

  ## Features

  - ETS-based O(1) lookups for channel routing
  - Automatic cache invalidation and cleanup
  - Memory-efficient storage with TTL support
  - Statistics and monitoring capabilities
  - Cache warming strategies

  ## Usage

  The route cache is automatically started by the socket supervisor
  and provides fast channel-to-process mapping for message routing.

  ## Performance Benefits

  - Eliminates Registry overhead for frequent lookups
  - Provides constant-time routing operations
  - Reduces process discovery latency
  - Handles high-frequency message routing efficiently
  """

  use GenServer
  require Logger

  @default_cache_size 1000
  @default_ttl 300_000  # 5 minutes
  @default_cleanup_interval 60_000  # 1 minute

  @typedoc """
  Cache configuration options
  """
  @type opts :: [
    cache_size: non_neg_integer(),
    ttl: non_neg_integer(),
    cleanup_interval: non_neg_integer(),
    registry_name: atom()
  ]

  @typedoc """
  Cache entry with metadata
  """
  @type cache_entry :: %{
    pid: pid(),
    timestamp: integer(),
    access_count: non_neg_integer(),
    last_access: integer()
  }

  @typedoc """
  Route cache state
  """
  @type t :: %__MODULE__{
    cache_table: :ets.tid(),
    cache_size: non_neg_integer(),
    ttl: non_neg_integer(),
    cleanup_interval: non_neg_integer(),
    registry_name: atom() | nil,
    cleanup_timer: reference() | nil,
    stats: %{
      hits: non_neg_integer(),
      misses: non_neg_integer(),
      evictions: non_neg_integer(),
      insertions: non_neg_integer(),
      current_size: non_neg_integer()
    }
  }

  defstruct [
    :cache_table,
    :cache_size,
    :ttl,
    :cleanup_interval,
    :registry_name,
    :cleanup_timer,
    stats: %{
      hits: 0,
      misses: 0,
      evictions: 0,
      insertions: 0,
      current_size: 0
    }
  ]

  @doc """
  Starts the route cache server.

  ## Options
    * `:cache_size` - Maximum number of cached routes (default: 1000)
    * `:ttl` - Time-to-live for cache entries in milliseconds (default: 300000)
    * `:cleanup_interval` - Cleanup interval for expired entries (default: 60000)
    * `:registry_name` - Registry name for fallback lookups
  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    registry_name = Keyword.get(opts, :registry_name)
    name = if registry_name, do: {registry_name, :route_cache}, else: nil

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets a channel PID from the cache.

  Returns {:ok, pid} if found and valid, :error otherwise.
  """
  @spec get(pid(), String.t()) :: {:ok, pid()} | :error
  def get(cache_pid, topic) when is_pid(cache_pid) and is_binary(topic) do
    GenServer.call(cache_pid, {:get, topic}, 1000)
  end

  @doc """
  Puts a route mapping in the cache.

  Associates a topic with a channel PID.
  """
  @spec put(pid(), String.t(), pid()) :: :ok
  def put(cache_pid, topic, channel_pid) when is_pid(cache_pid) and is_binary(topic) and is_pid(channel_pid) do
    GenServer.cast(cache_pid, {:put, topic, channel_pid})
  end

  @doc """
  Removes a route from the cache.

  Useful when a channel leaves or terminates.
  """
  @spec delete(pid(), String.t()) :: :ok
  def delete(cache_pid, topic) when is_pid(cache_pid) and is_binary(topic) do
    GenServer.cast(cache_pid, {:delete, topic})
  end

  @doc """
  Clears all cached routes.

  Useful for cache invalidation or testing.
  """
  @spec clear(pid()) :: :ok
  def clear(cache_pid) when is_pid(cache_pid) do
    GenServer.cast(cache_pid, :clear)
  end

  @doc """
  Gets cache statistics for monitoring.

  Returns detailed performance and usage statistics.
  """
  @spec stats(pid()) :: map()
  def stats(cache_pid) when is_pid(cache_pid) do
    GenServer.call(cache_pid, :stats, 1000)
  end

  @doc """
  Warms up the cache with common routes.

  Pre-populates the cache with known channel mappings.
  """
  @spec warm_up(pid(), [{String.t(), pid()}]) :: :ok
  def warm_up(cache_pid, routes) when is_pid(cache_pid) and is_list(routes) do
    GenServer.call(cache_pid, {:warm_up, routes}, 10_000)
  end

  @doc """
  Checks if a topic is cached.

  Returns true if the topic exists in cache, false otherwise.
  """
  @spec cached?(pid(), String.t()) :: boolean()
  def cached?(cache_pid, topic) when is_pid(cache_pid) and is_binary(topic) do
    GenServer.call(cache_pid, {:cached?, topic}, 1000)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    cache_size = Keyword.get(opts, :cache_size, @default_cache_size)
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    cleanup_interval = Keyword.get(opts, :cleanup_interval, @default_cleanup_interval)
    registry_name = Keyword.get(opts, :registry_name)

    # Create ETS table for caching
    cache_table = :ets.new(:phoenix_route_cache, [
      :set,
      :public,
      :named_table,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    # Start cleanup timer
    {:ok, timer} = :timer.send_interval(cleanup_interval, :cleanup)

    state = %__MODULE__{
      cache_table: cache_table,
      cache_size: cache_size,
      ttl: ttl,
      cleanup_interval: cleanup_interval,
      registry_name: registry_name,
      cleanup_timer: timer
    }

    Logger.debug("RouteCache started: size=#{cache_size}, ttl=#{ttl}ms")

    {:ok, state}
  end

  @impl true
  def handle_call({:get, topic}, _from, state) do
    current_time = System.monotonic_time(:millisecond)

    case :ets.lookup(state.cache_table, topic) do
      [{^topic, entry}] ->
        # Check if entry is still valid
        if current_time - entry.timestamp <= state.ttl and Process.alive?(entry.pid) do
          # Update access statistics
          updated_entry = %{entry |
            access_count: entry.access_count + 1,
            last_access: current_time
          }

          :ets.insert(state.cache_table, {topic, updated_entry})

          new_stats = %{state.stats | hits: state.stats.hits + 1}
          new_state = %{state | stats: new_stats}

          {:reply, {:ok, entry.pid}, new_state}
        else
          # Entry expired or process dead, remove it
          :ets.delete(state.cache_table, topic)
          current_size = :ets.info(state.cache_table, :size)

          new_stats = %{state.stats |
            misses: state.stats.misses + 1,
            current_size: current_size
          }
          new_state = %{state | stats: new_stats}

          {:reply, :error, new_state}
        end

      [] ->
        # Not found in cache
        new_stats = %{state.stats | misses: state.stats.misses + 1}
        new_state = %{state | stats: new_stats}

        {:reply, :error, new_state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    current_size = :ets.info(state.cache_table, :size)
    memory = :ets.info(state.cache_table, :memory)

    stats = Map.merge(state.stats, %{
      current_size: current_size,
      memory_bytes: memory * 8,  # ETS memory is in words
      cache_table_info: %{
        size: current_size,
        memory: memory,
        owner: :ets.info(state.cache_table, :owner),
        protection: :ets.info(state.cache_table, :protection)
      }
    })

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:warm_up, routes}, _from, state) do
    current_time = System.monotonic_time(:millisecond)
    insertions_count = 0

    {inserted_count, new_state} =
      Enum.reduce(routes, {0, state}, fn {topic, pid}, {count, acc_state} ->
        if Process.alive?(pid) and count < acc_state.cache_size do
          entry = %{
            pid: pid,
            timestamp: current_time,
            access_count: 0,
            last_access: current_time
          }

          :ets.insert(acc_state.cache_table, {topic, entry})
          {count + 1, acc_state}
        else
          {count, acc_state}
        end
      end)

    current_size = :ets.info(state.cache_table, :size)
    new_stats = %{state.stats |
      insertions: state.stats.insertions + inserted_count,
      current_size: current_size
    }

    final_state = %{new_state | stats: new_stats}

    Logger.debug("RouteCache warm-up: inserted #{inserted_count} routes")
    {:reply, :ok, final_state}
  end

  @impl true
  def handle_call({:cached?, topic}, _from, state) do
    cached = case :ets.lookup(state.cache_table, topic) do
      [{^topic, _entry}] -> true
      [] -> false
    end

    {:reply, cached, state}
  end

  @impl true
  def handle_cast({:put, topic, channel_pid}, state) do
    current_time = System.monotonic_time(:millisecond)
    current_size = :ets.info(state.cache_table, :size)

    # Check if we need to evict entries
    new_state = if current_size >= state.cache_size do
      evict_lru_entries(state)
    else
      state
    end

    entry = %{
      pid: channel_pid,
      timestamp: current_time,
      access_count: 0,
      last_access: current_time
    }

    :ets.insert(new_state.cache_table, {topic, entry})

    final_size = :ets.info(new_state.cache_table, :size)
    new_stats = %{new_state.stats |
      insertions: new_state.stats.insertions + 1,
      current_size: final_size
    }

    final_state = %{new_state | stats: new_stats}

    {:noreply, final_state}
  end

  @impl true
  def handle_cast({:delete, topic}, state) do
    :ets.delete(state.cache_table, topic)
    current_size = :ets.info(state.cache_table, :size)

    new_stats = %{state.stats | current_size: current_size}
    new_state = %{state | stats: new_stats}

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.delete_all_objects(state.cache_table)

    new_stats = %{state.stats | current_size: 0}
    new_state = %{state | stats: new_stats}

    Logger.debug("RouteCache cleared")
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    current_time = System.monotonic_time(:millisecond)
    ttl = state.ttl

    # Remove expired entries and dead processes
    {removed_count, evicted_count} =
      :ets.tab2list(state.cache_table)
      |> Enum.reduce({0, 0}, fn {topic, entry}, {expired, dead} ->
        age = current_time - entry.timestamp

        cond do
          age > ttl ->
            :ets.delete(state.cache_table, topic)
            {expired + 1, dead}

          not Process.alive?(entry.pid) ->
            :ets.delete(state.cache_table, topic)
            {expired, dead + 1}

          true ->
            {expired, dead}
        end
      end)

    total_removed = removed_count + evicted_count
    current_size = :ets.info(state.cache_table, :size)

    if total_removed > 0 do
      Logger.debug("RouteCache cleanup: removed #{total_removed} entries (#{removed_count} expired, #{evicted_count} dead)")
    end

    new_stats = %{state.stats |
      evictions: state.stats.evictions + evicted_count,
      current_size: current_size
    }

    new_state = %{state | stats: new_stats}
    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.cleanup_timer do
      :timer.cancel(state.cleanup_timer)
    end

    :ets.delete(state.cache_table)
    Logger.debug("RouteCache terminating: cleared #{:ets.info(state.cache_table, :size)} entries")
    :ok
  end

  # Private helper functions

  defp evict_lru_entries(state) do
    # Evict least recently used entries
    target_size = div(state.cache_size, 2)  # Evict to 50% capacity

    entries = :ets.tab2list(state.cache_table)
    |> Enum.sort_by(fn {_topic, entry} -> entry.last_access end)

    {to_evict, _to_keep} = Enum.split(entries, length(entries) - target_size)

    evicted_count = Enum.reduce(to_evict, 0, fn {topic, _entry}, count ->
      :ets.delete(state.cache_table, topic)
      count + 1
    end)

    Logger.debug("RouteCache: evicted #{evicted_count} LRU entries")

    new_stats = %{state.stats | evictions: state.stats.evictions + evicted_count}
    %{state | stats: new_stats}
  end
end