defmodule Phoenix.SocketClient.BinaryPool do
  @moduledoc """
  High-performance binary pooling for commonly used JSON patterns.

  This module implements a binary pooling mechanism to reduce memory allocation
  and garbage collection pressure for frequently used JSON patterns in Phoenix
  Channel messages. It provides:

  - Binary pooling for common message templates
  - Memory-efficient storage of repeated patterns
  - Fast lookup and retrieval of pooled binaries
  - Automatic cleanup of unused patterns

  ## Usage

  The pool is automatically started by the socket supervisor and can be used
  directly in message encoding/decoding operations.

  ## Performance Benefits

  - Reduces memory allocation for repeated patterns
  - Lowers GC pressure from frequent binary creation
  - Improves encoding/decoding performance for common messages
  - Provides consistent memory usage patterns
  """

  use GenServer
  require Logger

  @default_pool_size 1000
  @cleanup_interval 30_000
  # 5 minutes
  @max_age 300_000

  @typedoc """
  Pool configuration options
  """
  @type opts :: [
          pool_size: non_neg_integer(),
          cleanup_interval: non_neg_integer(),
          max_age: non_neg_integer(),
          registry_name: atom()
        ]

  @typedoc """
  Pool state structure
  """
  @type t :: %__MODULE__{
          pool_size: non_neg_integer(),
          cleanup_interval: non_neg_integer(),
          max_age: non_neg_integer(),
          registry_name: atom() | nil,
          patterns: %{
            binary() => %{count: non_neg_integer(), last_used: integer(), size: non_neg_integer()}
          },
          total_count: non_neg_integer(),
          total_memory: non_neg_integer()
        }

  defstruct [
    :pool_size,
    :cleanup_interval,
    :max_age,
    :registry_name,
    patterns: %{},
    total_count: 0,
    total_memory: 0
  ]

  @doc """
  Starts the binary pool server.

  ## Options
    * `:pool_size` - Maximum number of patterns to pool (default: 1000)
    * `:cleanup_interval` - Cleanup interval in milliseconds (default: 30000)
    * `:max_age` - Maximum age for patterns in milliseconds (default: 300000)
    * `:registry_name` - Registry name for process registration
  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = if Keyword.keyword?(opts), do: opts, else: Enum.into(opts, [])
    registry_name = Keyword.get(opts, :registry_name)
    name = if registry_name, do: {:via, Registry, {registry_name, :binary_pool}}, else: nil

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets a pooled binary if available, otherwise stores the provided binary.

  Returns the pooled binary reference.
  """
  @spec get_or_pool(pid(), binary()) :: binary()
  def get_or_pool(pool_pid, binary) when is_pid(pool_pid) do
    GenServer.call(pool_pid, {:get_or_pool, binary}, 5000)
  end

  @doc """
  Gets a pooled binary without storing if not found.

  Returns {:ok, binary} if found, :error otherwise.
  """
  @spec get(pid(), binary()) :: {:ok, binary()} | :error
  def get(pool_pid, binary) when is_pid(pool_pid) do
    GenServer.call(pool_pid, {:get, binary}, 1000)
  end

  @doc """
  Pre-populates the pool with common message patterns.

  Useful for warming up the pool with known patterns.
  """
  @spec warm_up(pid(), list(binary())) :: :ok
  def warm_up(pool_pid, patterns) when is_pid(pool_pid) and is_list(patterns) do
    GenServer.call(pool_pid, {:warm_up, patterns}, 10_000)
  end

  @doc """
  Gets pool statistics for monitoring.
  """
  @spec stats(pid()) :: map()
  def stats(pool_pid) when is_pid(pool_pid) do
    GenServer.call(pool_pid, :stats, 1000)
  end

  @doc """
  Creates common Phoenix Channel message patterns for warm-up.

  Returns a list of JSON binaries for common message types.
  """
  @spec common_patterns() :: list(binary())
  def common_patterns do
    json_lib = Application.get_env(:phoenix_socket_client, :json_library, Jason)

    # Common Phoenix Channel message patterns
    [
      # Join messages
      json_lib.encode!(%{
        "topic" => "phoenix",
        "event" => "phx_join",
        "payload" => %{},
        "ref" => "1",
        "join_ref" => "1"
      }),

      # Heartbeat
      json_lib.encode!(%{
        "topic" => "phoenix",
        "event" => "heartbeat",
        "payload" => %{},
        "ref" => "2"
      }),

      # Common channel events
      json_lib.encode!(%{
        "topic" => "rooms:lobby",
        "event" => "phx_join",
        "payload" => %{},
        "ref" => "3"
      }),
      json_lib.encode!(%{
        "topic" => "rooms:lobby",
        "event" => "shout",
        "payload" => %{"body" => "", "user" => ""},
        "ref" => "4"
      }),

      # System events
      json_lib.encode!(%{
        "topic" => "phoenix",
        "event" => "phx_reply",
        "payload" => %{"response" => %{}, "status" => "ok"},
        "ref" => "5"
      })
    ]
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)
    cleanup_interval = Keyword.get(opts, :cleanup_interval, @cleanup_interval)
    max_age = Keyword.get(opts, :max_age, @max_age)
    registry_name = Keyword.get(opts, :registry_name)

    # Start cleanup timer
    :timer.send_interval(cleanup_interval, :cleanup)

    state = %__MODULE__{
      pool_size: pool_size,
      cleanup_interval: cleanup_interval,
      max_age: max_age,
      registry_name: registry_name
    }

    # Warm up with common patterns
    Task.start(fn ->
      # Give time for system to stabilize
      :timer.sleep(1000)
      warm_up_common_patterns(state)
    end)

    {:ok, state}
  end

  @impl true
  def handle_call({:get_or_pool, binary}, _from, state) do
    binary_size = byte_size(binary)

    case Map.get(state.patterns, binary) do
      nil ->
        # New pattern, add to pool if space available
        if map_size(state.patterns) < state.pool_size do
          pattern_info = %{
            count: 1,
            last_used: System.monotonic_time(:millisecond),
            size: binary_size
          }

          new_patterns = Map.put(state.patterns, binary, pattern_info)

          new_state = %{
            state
            | patterns: new_patterns,
              total_count: state.total_count + 1,
              total_memory: state.total_memory + binary_size
          }

          {:reply, binary, new_state}
        else
          # Pool full, return original binary
          {:reply, binary, state}
        end

      pattern_info ->
        # Existing pattern, update usage stats
        updated_info = %{
          pattern_info
          | count: pattern_info.count + 1,
            last_used: System.monotonic_time(:millisecond)
        }

        new_patterns = Map.put(state.patterns, binary, updated_info)
        new_state = %{state | patterns: new_patterns}

        {:reply, binary, new_state}
    end
  end

  @impl true
  def handle_call({:get, binary}, _from, state) do
    case Map.get(state.patterns, binary) do
      nil -> {:reply, :error, state}
      _pattern_info -> {:reply, {:ok, binary}, state}
    end
  end

  @impl true
  def handle_call({:warm_up, patterns}, _from, state) do
    new_state =
      Enum.reduce(patterns, state, fn binary, acc_state ->
        binary_size = byte_size(binary)

        if map_size(acc_state.patterns) < acc_state.pool_size do
          pattern_info = %{
            count: 1,
            last_used: System.monotonic_time(:millisecond),
            size: binary_size
          }

          %{
            acc_state
            | patterns: Map.put(acc_state.patterns, binary, pattern_info),
              total_count: acc_state.total_count + 1,
              total_memory: acc_state.total_memory + binary_size
          }
        else
          acc_state
        end
      end)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      pool_size: map_size(state.patterns),
      max_pool_size: state.pool_size,
      total_count: state.total_count,
      total_memory_bytes: state.total_memory,
      total_memory_mb: state.total_memory / (1024 * 1024),
      average_pattern_size:
        if(state.total_count > 0, do: state.total_memory / state.total_count, else: 0),
      oldest_pattern_age: find_oldest_pattern_age(state.patterns),
      newest_pattern_age: find_newest_pattern_age(state.patterns)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    current_time = System.monotonic_time(:millisecond)
    max_age = state.max_age

    # Remove old patterns
    {active_patterns, removed_patterns} =
      state.patterns
      |> Enum.split_with(fn {_binary, pattern_info} ->
        current_time - pattern_info.last_used < max_age
      end)

    # Calculate removed memory
    removed_memory =
      Enum.reduce(removed_patterns, 0, fn {_binary, pattern_info}, acc ->
        acc + pattern_info.size
      end)

    removed_count = length(removed_patterns)

    new_state = %{
      state
      | patterns: Map.new(active_patterns),
        total_count: state.total_count - removed_count,
        total_memory: state.total_memory - removed_memory
    }

    if removed_count > 0 do
      Phoenix.SocketClient.Telemetry.optimization(:binary_pool_cleanup, %{
        patterns_removed: removed_count,
        memory_freed_bytes: removed_memory,
        pool_size: map_size(state.patterns)
      })
    end

    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    Phoenix.SocketClient.Telemetry.optimization(:binary_pool_terminating, %{
      patterns_count: map_size(state.patterns),
      total_memory: state.total_memory
    })

    :ok
  end

  # Private helper functions

  defp warm_up_common_patterns(_state) do
    try do
      patterns = common_patterns()
      GenServer.call(self(), {:warm_up, patterns}, 5000)

      Phoenix.SocketClient.Telemetry.optimization(:binary_pool_warmup, %{
        patterns_count: length(patterns)
      })
    catch
      :exit, _ ->
        Phoenix.SocketClient.Telemetry.optimization(:binary_pool_warmup_failed, %{
          reason: :server_terminating
        })
    end
  end

  defp find_oldest_pattern_age(patterns) do
    current_time = System.monotonic_time(:millisecond)

    case Enum.min_by(
           patterns,
           fn {_binary, pattern_info} ->
             pattern_info.last_used
           end,
           fn -> nil end
         ) do
      {_binary, pattern_info} -> current_time - pattern_info.last_used
      nil -> 0
    end
  end

  defp find_newest_pattern_age(patterns) do
    current_time = System.monotonic_time(:millisecond)

    case Enum.max_by(
           patterns,
           fn {_binary, pattern_info} ->
             pattern_info.last_used
           end,
           fn -> nil end
         ) do
      {_binary, pattern_info} -> current_time - pattern_info.last_used
      nil -> 0
    end
  end
end
