defmodule Phoenix.SocketClient.Router do
  @moduledoc """
  High-performance message routing utilities.

  This module provides optimized message routing functions that use
  the route cache for fast channel discovery while falling back to
  Registry lookups when necessary.

  ## Features

  - Cached route lookups for performance
  - Automatic cache population on successful lookups
  - Fallback to Registry for cache misses
  - Route statistics and monitoring
  - Configurable routing strategies

  ## Usage

  The router is used internally by message processing components
  to provide fast channel-to-process mapping.

  ## Performance Benefits

  - O(1) cached lookups vs O(n) Registry operations
  - Automatic cache warming for frequently accessed channels
  - Reduced process discovery overhead
  - Scalable routing for high message volumes
  """

  alias Phoenix.SocketClient.RouteCache

  @typedoc """
  Routing options
  """
  @type opts :: [
    cache_pid: pid(),
    registry_name: atom(),
    use_cache: boolean(),
    cache_on_hit: boolean()
  ]

  @doc """
  Routes a message to the appropriate channel process.

  This function attempts to find the channel PID using the cache first,
  then falls back to Registry lookups if the cache miss occurs.

  ## Parameters
    * `topic` - The channel topic to route to
    * `opts` - Routing options including cache PID and registry name

  ## Returns
    * `{:ok, pid}` - Channel process found
    * `:error` - Channel not found

  ## Examples
      {:ok, pid} = Router.route_message("rooms:lobby", [
        cache_pid: cache_pid,
        registry_name: MyRegistry
      ])
  """
  @spec route_message(String.t(), opts()) :: {:ok, pid()} | :error
  def route_message(topic, opts \\ []) when is_binary(topic) do
    cache_pid = Keyword.get(opts, :cache_pid)
    registry_name = Keyword.get(opts, :registry_name)
    use_cache = Keyword.get(opts, :use_cache, true)
    cache_on_hit = Keyword.get(opts, :cache_on_hit, true)

    cond do
      use_cache and cache_pid ->
        route_with_cache(topic, cache_pid, registry_name, cache_on_hit)

      registry_name ->
        route_with_registry(topic, registry_name, cache_pid, cache_on_hit)

      true ->
        :error
    end
  end

  @doc """
  Routes multiple messages efficiently.

  Processes a batch of topics and returns their corresponding PIDs.
  Uses cached lookups where possible and Registry fallbacks.

  ## Parameters
    * `topics` - List of channel topics to route
    * `opts` - Routing options

  ## Returns
    * List of `{:ok, pid}` or `:error` results for each topic

  ## Examples
      results = Router.route_batch(["rooms:lobby", "users:123"], opts)
  """
  @spec route_batch([String.t()], opts()) :: [{:ok, pid()} | :error]
  def route_batch(topics, opts \\ []) when is_list(topics) do
    Enum.map(topics, &route_message(&1, opts))
  end

  @doc """
  Pre-populates the route cache with known channels.

  Useful for warming up the cache with expected channels.

  ## Parameters
    * `routes` - List of {topic, pid} tuples
    * `cache_pid` - Route cache process PID

  ## Returns
    * `:ok` on success, `{:error, reason}` on failure
  """
  @spec warm_up_cache([{String.t(), pid()}], pid()) :: :ok | {:error, term()}
  def warm_up_cache(routes, cache_pid) when is_list(routes) and is_pid(cache_pid) do
    RouteCache.warm_up(cache_pid, routes)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Invalidates a cached route.

  Removes a topic from the route cache, forcing the next lookup
  to use Registry and potentially update the cache with fresh data.

  ## Parameters
    * `topic` - The channel topic to invalidate
    * `cache_pid` - Route cache process PID

  ## Returns
    * `:ok` on success
  """
  @spec invalidate_route(String.t(), pid()) :: :ok
  def invalidate_route(topic, cache_pid) when is_binary(topic) and is_pid(cache_pid) do
    RouteCache.delete(cache_pid, topic)
  catch
    :exit, _ -> :ok  # Cache might be unavailable
  end

  @doc """
  Gets routing statistics for monitoring.

  Returns statistics about cache performance and routing operations.

  ## Parameters
    * `cache_pid` - Route cache process PID

  ## Returns
    * Statistics map with hit rates, cache size, etc.
  """
  @spec routing_stats(pid()) :: map()
  def routing_stats(cache_pid) when is_pid(cache_pid) do
    RouteCache.stats(cache_pid)
  catch
    :exit, _ -> %{error: "cache_unavailable"}
  end

  @doc """
  Checks if a route is cached.

  Returns true if the topic exists in the route cache.

  ## Parameters
    * `topic` - The channel topic to check
    * `cache_pid` - Route cache process PID

  ## Returns
    * `true` if cached, `false` otherwise
  """
  @spec route_cached?(String.t(), pid()) :: boolean()
  def route_cached?(topic, cache_pid) when is_binary(topic) and is_pid(cache_pid) do
    RouteCache.cached?(cache_pid, topic)
  catch
    :exit, _ -> false
  end

  @doc """
  Clears all cached routes.

  Useful for cache invalidation or testing.

  ## Parameters
    * `cache_pid` - Route cache process PID

  ## Returns
    * `:ok` on success
  """
  @spec clear_cache(pid()) :: :ok
  def clear_cache(cache_pid) when is_pid(cache_pid) do
    RouteCache.clear(cache_pid)
  catch
    :exit, _ -> :ok
  end

  # Private helper functions

  defp route_with_cache(topic, cache_pid, registry_name, cache_on_hit) do
    case RouteCache.get(cache_pid, topic) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        # Cache miss, try registry
        case registry_name && Registry.lookup(registry_name, topic) do
          [{pid, _}] when is_pid(pid) ->
            # Found in registry, optionally cache it
            if cache_on_hit do
              RouteCache.put(cache_pid, topic, pid)
            end
            {:ok, pid}

          _ ->
            # Not found in registry either
            :error
        end
    end
  catch
    :exit, _ ->
      # Cache process died, fall back to registry
      route_with_registry(topic, registry_name, nil, false)
  end

  defp route_with_registry(topic, registry_name, cache_pid, cache_on_hit) do
    case registry_name && Registry.lookup(registry_name, topic) do
      [{pid, _}] when is_pid(pid) ->
        # Found in registry, optionally cache it
        if cache_on_hit && cache_pid do
          RouteCache.put(cache_pid, topic, pid)
        end
        {:ok, pid}

      _ ->
        # Not found
        :error
    end
  rescue
    ArgumentError -> :error  # Registry might not exist
  end
end