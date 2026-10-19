defmodule Phoenix.SocketClient.ConfigStore do
  @moduledoc false

  use GenServer
  use Phoenix.SocketClient.Privacy

  def new(options), do: GenServer.start(__MODULE__, options)
  def options(store), do: GenServer.call(store, :options)
  def put_options(store, options), do: GenServer.call(store, {:put_options, options})
  def bind_owner(store, owner), do: GenServer.call(store, {:bind_owner, owner})
  def close(store), do: GenServer.stop(store, :normal)
  def discard(store), do: GenServer.call(store, :discard)

  def start_child(module, store) do
    safe_start({module, :start_link, [options(store)]})
  end

  def put_channel(store, start, manager),
    do: GenServer.call(store, {:put_channel, start, manager})

  def delete_channel(store, key), do: GenServer.call(store, {:delete_channel, key})

  def start_channel(store, key) do
    start = GenServer.call(store, {:channel_start, key})

    case safe_start(start) do
      {:ok, pid} = result ->
        :ok = GenServer.call(store, {:track_channel, key, pid})
        result

      {:ok, pid, _info} = result ->
        :ok = GenServer.call(store, {:track_channel, key, pid})
        result

      result ->
        result
    end
  end

  defp safe_start({module, function, args}) do
    case apply(module, function, args) do
      {:ok, pid} = result when is_pid(pid) -> result
      {:ok, pid, _info} = result when is_pid(pid) -> result
      {:error, {:already_started, pid}} = result when is_pid(pid) -> result
      {:error, {:already_registered, pid}} = result when is_pid(pid) -> result
      :ignore -> :ignore
      _private_error -> {:error, :private_callback_failure}
    end
  catch
    _kind, _private_reason -> {:error, :private_callback_failure}
  end

  @impl true
  def init(options),
    do: {:ok, %{options: options, owner: nil, channels: %{}, monitors: %{}}}

  @impl true
  def format_status(status), do: Phoenix.SocketClient.Privacy.format_status(status)

  @impl true
  def handle_call(:options, _from, state), do: {:reply, state.options, state}

  def handle_call(:discard, _from, %{owner: nil} = state), do: {:stop, :normal, :ok, state}
  def handle_call(:discard, _from, state), do: {:reply, {:error, :in_use}, state}

  def handle_call({:put_options, options}, _from, state),
    do: {:reply, :ok, %{state | options: options}}

  def handle_call({:bind_owner, owner}, _from, %{owner: nil} = state) do
    ref = Process.monitor(owner)
    {:reply, :ok, %{state | owner: {owner, ref}}}
  end

  def handle_call({:bind_owner, owner}, _from, %{owner: {owner, _ref}} = state),
    do: {:reply, :ok, state}

  def handle_call({:bind_owner, _owner}, _from, state),
    do: {:reply, {:error, :different_owner}, state}

  def handle_call({:put_channel, start, manager}, _from, state) do
    key = make_ref()
    monitor = Process.monitor(manager)
    channels = Map.put(state.channels, key, %{start: start, manager: manager})
    monitors = Map.put(state.monitors, monitor, {:manager, key})
    {:reply, key, %{state | channels: channels, monitors: monitors}}
  end

  def handle_call({:channel_start, key}, _from, state),
    do: {:reply, Map.fetch!(state.channels, key).start, state}

  def handle_call({:track_channel, key, pid}, _from, state) do
    monitor = Process.monitor(pid)
    monitors = Map.put(state.monitors, monitor, {:channel, key, pid})
    {:reply, :ok, %{state | monitors: monitors}}
  end

  def handle_call({:delete_channel, key}, _from, state),
    do: {:reply, :ok, delete_entry(state, key)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner: {_owner, ref}} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {entry, monitors} = Map.pop(state.monitors, ref)
    state = %{state | monitors: monitors}

    case entry do
      {:manager, key} ->
        {:noreply, delete_entry(state, key)}

      {:channel, key, _pid} when reason in [:normal, :shutdown] ->
        {:noreply, delete_entry(state, key)}

      _ ->
        {:noreply, state}
    end
  end

  defp delete_entry(state, key) do
    monitors =
      Map.reject(state.monitors, fn {ref, entry} ->
        if elem(entry, 1) == key do
          Process.demonitor(ref, [:flush])
          true
        else
          false
        end
      end)

    %{state | channels: Map.delete(state.channels, key), monitors: monitors}
  end

  @impl true
  def terminate(_reason, _state), do: :ok
end
