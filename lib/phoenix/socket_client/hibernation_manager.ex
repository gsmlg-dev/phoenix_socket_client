defmodule Phoenix.SocketClient.HibernationManager do
  @moduledoc """
  Process hibernation manager for idle connections.

  This module provides intelligent hibernation for long-lived processes
  to reduce memory footprint when connections are idle. It monitors process
  activity and automatically hibernates processes that have been idle
  for a configurable period.

  ## Features

  - Automatic detection of idle processes
  - Configurable hibernation thresholds
  - Memory-efficient hibernation strategy
  - Activity monitoring and wake-up handling
  - Process lifecycle management

  ## Usage

  The hibernation manager is automatically started by the socket supervisor
  and monitors all socket-related processes for inactivity.

  ## Performance Benefits

  - Reduces memory usage for idle connections
  - Lowers GC pressure from idle processes
  - Maintains responsiveness while optimizing memory
  - Provides configurable hibernation policies
  """

  use GenServer
  require Logger

  @default_idle_timeout 300_000  # 5 minutes
  @default_check_interval 60_000  # 1 minute
  @default_memory_threshold 10_000  # 10KB minimum memory before hibernation

  @typedoc """
  Hibernation manager configuration options
  """
  @type opts :: [
    idle_timeout: non_neg_integer(),
    check_interval: non_neg_integer(),
    memory_threshold: non_neg_integer(),
    registry_name: atom()
  ]

  @typedoc """
  Tracked process information
  """
  @type process_info :: %{
    pid: pid(),
    last_activity: integer(),
    memory: non_neg_integer(),
    hibernated_count: non_neg_integer(),
    name: atom() | {atom(), atom()}
  }

  @typedoc """
  Hibernation manager state
  """
  @type t :: %__MODULE__{
    idle_timeout: non_neg_integer(),
    check_interval: non_neg_integer(),
    memory_threshold: non_neg_integer(),
    registry_name: atom() | nil,
    tracked_processes: %{pid() => process_info()},
    check_timer: reference() | nil,
    stats: %{
      total_hibernations: non_neg_integer(),
      total_memory_saved: non_neg_integer(),
      current_tracked: non_neg_integer(),
      current_hibernated: non_neg_integer()
    }
  }

  defstruct [
    :idle_timeout,
    :check_interval,
    :memory_threshold,
    :registry_name,
    tracked_processes: %{},
    check_timer: nil,
    stats: %{
      total_hibernations: 0,
      total_memory_saved: 0,
      current_tracked: 0,
      current_hibernated: 0
    }
  ]

  @doc """
  Starts the hibernation manager.

  ## Options
    * `:idle_timeout` - Time in milliseconds before considering a process idle (default: 300000)
    * `:check_interval` - Interval for checking idle processes (default: 60000)
    * `:memory_threshold` - Minimum memory usage before hibernation (default: 10000)
    * `:registry_name` - Registry name for process discovery
  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    registry_name = Keyword.get(opts, :registry_name)
    name = if registry_name, do: {registry_name, :hibernation_manager}, else: nil

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a process for hibernation monitoring.

  The process will be tracked for activity and hibernated when idle.
  """
  @spec register_process(pid(), atom() | {atom(), atom()}) :: :ok
  def register_process(pid, name \\ nil) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:register_process, pid, name})
  end

  @doc """
  Unregisters a process from hibernation monitoring.

  The process will no longer be tracked for hibernation.
  """
  @spec unregister_process(pid()) :: :ok
  def unregister_process(pid) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:unregister_process, pid})
  end

  @doc """
  Reports activity for a process.

  This should be called when a process receives a message or performs work
  to update its activity timestamp and prevent premature hibernation.
  """
  @spec report_activity(pid()) :: :ok
  def report_activity(pid) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:report_activity, pid})
  end

  @doc """
  Gets hibernation statistics for monitoring.

  Returns statistics about hibernation effectiveness and current state.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats, 5000)
  end

  @doc """
  Forces hibernation of a specific process.

  Useful for manual hibernation during maintenance or testing.
  """
  @spec hibernate_process(pid()) :: :ok | {:error, term()}
  def hibernate_process(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:hibernate_process, pid}, 5000)
  end

  @doc """
  Manually wakes up a hibernated process.

  This is typically handled automatically when messages are received.
  """
  @spec wake_up_process(pid()) :: :ok | {:error, term()}
  def wake_up_process(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:wake_up_process, pid}, 5000)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    idle_timeout = Keyword.get(opts, :idle_timeout, @default_idle_timeout)
    check_interval = Keyword.get(opts, :check_interval, @default_check_interval)
    memory_threshold = Keyword.get(opts, :memory_threshold, @default_memory_threshold)
    registry_name = Keyword.get(opts, :registry_name)

    # Start periodic check timer
    {:ok, timer} = :timer.send_interval(check_interval, :check_idle_processes)

    state = %__MODULE__{
      idle_timeout: idle_timeout,
      check_interval: check_interval,
      memory_threshold: memory_threshold,
      registry_name: registry_name,
      check_timer: timer
    }

    Logger.debug("HibernationManager started: idle_timeout=#{idle_timeout}ms, check_interval=#{check_interval}ms")

    {:ok, state}
  end

  @impl true
  def handle_cast({:register_process, pid, name}, state) do
    if Process.alive?(pid) do
      {:memory, memory} = :erlang.process_info(pid, :memory)
      current_time = System.monotonic_time(:millisecond)

      process_info = %{
        pid: pid,
        last_activity: current_time,
        memory: memory,
        hibernated_count: 0,
        name: name || pid
      }

      new_tracked = Map.put(state.tracked_processes, pid, process_info)
      current_count = map_size(new_tracked)

      new_state = %{state |
        tracked_processes: new_tracked,
        stats: %{state.stats | current_tracked: current_count}
      }

      # Monitor the process for termination
      Process.monitor(pid)

      Logger.debug("HibernationManager: registered process #{inspect(name || pid)} (#{memory} words)")
      {:noreply, new_state}
    else
      Logger.warn("HibernationManager: attempted to register dead process #{inspect(pid)}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:unregister_process, pid}, state) do
    case Map.get(state.tracked_processes, pid) do
      nil ->
        {:noreply, state}

      _process_info ->
        new_tracked = Map.delete(state.tracked_processes, pid)
        current_count = map_size(new_tracked)

        new_state = %{state |
          tracked_processes: new_tracked,
          stats: %{state.stats | current_tracked: current_count}
        }

        Logger.debug("HibernationManager: unregistered process #{inspect(pid)}")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:report_activity, pid}, state) do
    case Map.get(state.tracked_processes, pid) do
      nil ->
        {:noreply, state}

      process_info ->
        current_time = System.monotonic_time(:millisecond)
        updated_info = %{process_info | last_activity: current_time}

        new_tracked = Map.put(state.tracked_processes, pid, updated_info)
        new_state = %{state | tracked_processes: new_tracked}

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Map.merge(state.stats, %{
      idle_timeout: state.idle_timeout,
      check_interval: state.check_interval,
      memory_threshold: state.memory_threshold,
      oldest_idle_time: find_oldest_idle_time(state.tracked_processes, state.idle_timeout)
    })

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:hibernate_process, pid}, _from, state) do
    case Map.get(state.tracked_processes, pid) do
      nil ->
        {:reply, {:error, :not_tracked}, state}

      process_info ->
        case attempt_hibernation(pid, process_info, state.memory_threshold) do
          :ok ->
            updated_info = %{process_info | hibernated_count: process_info.hibernated_count + 1}
            new_tracked = Map.put(state.tracked_processes, pid, updated_info)
            hibernated_count = count_hibernated(new_tracked)

            new_state = %{state |
              tracked_processes: new_tracked,
              stats: %{state.stats | current_hibernated: hibernated_count}
            }

            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:wake_up_process, pid}, _from, state) do
    case Map.get(state.tracked_processes, pid) do
      nil ->
        {:reply, {:error, :not_tracked}, state}

      process_info ->
        current_time = System.monotonic_time(:millisecond)
        updated_info = %{process_info | last_activity: current_time}

        new_tracked = Map.put(state.tracked_processes, pid, updated_info)
        hibernated_count = count_hibernated(new_tracked)

        new_state = %{state |
          tracked_processes: new_tracked,
          stats: %{state.stats | current_hibernated: hibernated_count}
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info(:check_idle_processes, state) do
    current_time = System.monotonic_time(:millisecond)
    idle_timeout = state.idle_timeout

    # Find processes that should be hibernated
    {to_hibernate, remaining} =
      Enum.split_with(state.tracked_processes, fn {_pid, process_info} ->
        current_time - process_info.last_activity > idle_timeout and
        process_info.memory >= state.memory_threshold
      end)

    # Hibernate idle processes
    {hibernated_count, memory_saved} =
      Enum.reduce(to_hibernate, {0, 0}, fn {pid, process_info}, {count, memory} ->
        case attempt_hibernation(pid, process_info, state.memory_threshold) do
          :ok ->
            Logger.debug("HibernationManager: hibernated process #{inspect(process_info.name)} (#{process_info.memory} words)")
            {count + 1, memory + process_info.memory}

          {:error, _reason} ->
            {count, memory}
        end
      end)

    # Update statistics
    if hibernated_count > 0 do
      new_stats = %{
        state.stats |
        total_hibernations: state.stats.total_hibernations + hibernated_count,
        total_memory_saved: state.stats.total_memory_saved + memory_saved,
        current_hibernated: state.stats.current_hibernated + hibernated_count
      }

      Logger.debug("HibernationManager: hibernated #{hibernated_count} processes, saved #{memory_saved} words")
      {:noreply, %{state | stats: new_stats}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Process died, remove from tracking
    case Map.get(state.tracked_processes, pid) do
      nil ->
        {:noreply, state}

      _process_info ->
        new_tracked = Map.delete(state.tracked_processes, pid)
        current_count = map_size(new_tracked)

        new_state = %{state |
          tracked_processes: new_tracked,
          stats: %{state.stats | current_tracked: current_count}
        }

        Logger.debug("HibernationManager: removed dead process #{inspect(pid)}")
        {:noreply, new_state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.check_timer do
      :timer.cancel(state.check_timer)
    end

    Logger.debug("HibernationManager terminating: tracked #{map_size(state.tracked_processes)} processes")
    :ok
  end

  # Private helper functions

  defp attempt_hibernation(pid, process_info, memory_threshold) do
    if process_info.memory >= memory_threshold do
      try do
        # Send hibernation request
        send(pid, :hibernate_request)

        # Check if process is still alive and responsive
        case :erlang.process_info(pid, :message_queue_len) do
          {:message_queue_len, _} -> :ok
          undefined -> {:error, :process_not_responsive}
        end
      catch
        :exit, reason -> {:error, reason}
      end
    else
      {:error, :memory_too_low}
    end
  end

  defp count_hibernated(tracked_processes) do
    Enum.count(tracked_processes, fn {_pid, process_info} ->
      try do
        # Check if process is currently hibernated by examining its state
        case :erlang.process_info(process_info.pid, :status) do
          {:status, :hibernating} -> true
          _ -> false
        end
      rescue
        ArgumentError -> false  # Process might have died
      end
    end)
  end

  defp find_oldest_idle_time(tracked_processes, idle_timeout) do
    current_time = System.monotonic_time(:millisecond)

    case Enum.min_by(tracked_processes, fn {_pid, process_info} ->
      current_time - process_info.last_activity
    end, fn -> nil end) do
      {_pid, process_info} ->
        idle_time = current_time - process_info.last_activity
        if idle_time > idle_timeout, do: idle_time, else: 0
      nil -> 0
    end
  end
end