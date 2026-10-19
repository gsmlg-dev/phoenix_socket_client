defmodule Phoenix.SocketClient.SupervisorPrivacyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Phoenix.SocketClient, as: Client
  alias Phoenix.SocketClient.{Channel, ChannelManager}

  @sentinel "SUPERVISOR_PRIVATE_MATERIAL_SENTINEL"

  defmodule InfoChannel do
    use Phoenix.SocketClient.Channel

    defoverridable start_link: 1

    def start_link(args) do
      case super(args) do
        {:ok, pid} -> {:ok, pid, :channel_info}
        result -> result
      end
    end

    @impl true
    def handle_message(_event, _payload, state), do: {:noreply, state}
  end

  defmodule FailedStartChannel do
    use Phoenix.SocketClient.Channel

    @impl true
    def init({_sup, _socket, _topic, params, _registry}),
      do: {:stop, {:private_init_failure, params["private_key"]}}

    @impl true
    def handle_message(_event, _payload, state), do: {:noreply, state}
  end

  setup do
    observer = fn event, owner ->
      send(owner, {:supervisor_log, event})
      :ignore
    end

    :ok = :logger.add_primary_filter(__MODULE__, {observer, self()})
    on_exit(fn -> :logger.remove_primary_filter(__MODULE__) end)
    :ok
  end

  test "opaque supervisor specifications preserve private configuration across root restarts" do
    parent = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    owner = self()

    creator =
      spawn_monitor(fn ->
        send(owner, {:private_spec, Client.child_spec(options(:private_root_restart))})
      end)

    assert_receive {:private_spec, spec}
    {creator_pid, creator_ref} = creator
    assert_receive {:DOWN, ^creator_ref, :process, ^creator_pid, :normal}
    assert_private(spec)
    {_, _, [{:supervised, store}]} = spec.start
    store_monitor = Process.monitor(store)

    log =
      capture_log(fn ->
        assert {:ok, root} = DynamicSupervisor.start_child(parent, spec)
        assert {:error, :in_use} = Client.discard_child_spec(spec)
        assert_private(:sys.get_status(parent))
        assert_private(:sys.get_status(root))
        assert_private(:sys.get_status(store))
        assert Client.get_state(root, :transport_opts)[:ssl] == [keyfile: @sentinel]

        monitor = Process.monitor(root)
        assert :ok = Supervisor.stop(root, :shutdown)
        assert_receive {:DOWN, ^monitor, :process, ^root, :shutdown}

        replacement =
          await(fn ->
            Enum.find_value(DynamicSupervisor.which_children(parent), fn
              {_, pid, _, _} when is_pid(pid) and pid != root -> pid
              _ -> nil
            end)
          end)

        assert Client.get_state(replacement, :transport_opts)[:ssl] == [keyfile: @sentinel]
        assert_private(:sys.get_status(replacement))
      end)

    refute log =~ @sentinel
    reports = reports([])
    assert Enum.any?(reports, &match?(%{msg: {:report, %{label: {:supervisor, :progress}}}}, &1))
    assert_private(reports)
    assert :ok = stop_supervised(DynamicSupervisor)
    assert_receive {:DOWN, ^store_monitor, :process, ^store, :normal}
  end

  test "supervisor crash reports and channel restarts do not retain private start arguments" do
    root = start_supervised!({Client, options(:private_channel_specs)})
    manager = Client.get_process_pid(root, :channel_manager)
    store = Client.get_state(root, :private_config)
    params = %{"private_key" => @sentinel}
    registry = Client.get_state(root, :registry_name)

    log =
      capture_log(fn ->
        assert {:ok, channel} = ChannelManager.start_channel(root, "private:topic", params)
        monitor = Process.monitor(channel)
        assert_private(:sys.get_status(manager))
        assert_private(:sys.get_status(store))
        send(channel, {:"$gen_call", {self(), make_ref()}, {:private_call, @sentinel}})

        assert_receive {:DOWN, ^monitor, :process, ^channel, :private_callback_failure}

        replacement =
          await(fn ->
            case Registry.lookup(registry, "private:topic") do
              [{pid, _}] when pid != channel -> pid
              _ -> nil
            end
          end)

        assert :sys.get_state(replacement).params == params
        assert_private(:sys.get_status(manager))
        assert :ok = Channel.leave(replacement)
        await(fn -> :sys.get_state(store).channels == %{} end)
      end)

    assert log =~ "terminating"
    refute log =~ @sentinel
    reports = reports([])

    assert Enum.any?(reports, fn
             %{msg: {:report, %{label: {:supervisor, :child_terminated}}}} -> true
             _ -> false
           end)

    assert_private(reports)
  end

  test "direct starts release private configuration when the client stops" do
    assert {:ok, root} = Client.start_link(options(:private_direct_start))
    Process.unlink(root)
    store = Client.get_state(root, :private_config)
    monitor = Process.monitor(store)
    assert {:error, :in_use} = Phoenix.SocketClient.ConfigStore.discard(store)
    assert_private(:sys.get_status(root))
    assert :ok = Supervisor.stop(root)
    assert_receive {:DOWN, ^monitor, :process, ^store, :normal}
  end

  test "unused child specifications can release their private configuration" do
    spec = Client.child_spec(options(:private_unused_spec))
    {_, _, [{:supervised, store}]} = spec.start
    monitor = Process.monitor(store)
    assert :ok = Client.discard_child_spec(spec)
    assert_receive {:DOWN, ^monitor, :process, ^store, :normal}
  end

  test "invalid private startup options do not escape through root initialization reports" do
    log =
      capture_log(fn ->
        starter =
          Task.async(fn ->
            Process.flag(:trap_exit, true)

            options(:private_invalid_start)
            |> Keyword.put(:registry_name, @sentinel)
            |> Client.start_link()
          end)

        assert Task.await(starter) == {:error, :private_callback_failure}
      end)

    assert log =~ "terminating"
    refute log =~ @sentinel
    assert_private(reports([]))
  end

  test "three-tuple channel starts retain restart configuration and isolate failed starts" do
    opts = Keyword.put(options(:private_info_channel), :default_channel_module, InfoChannel)
    root = start_supervised!({Client, opts})
    store = Client.get_state(root, :private_config)
    registry = Client.get_state(root, :registry_name)
    params = %{"private_key" => @sentinel}

    log =
      capture_log(fn ->
        assert {:ok, channel, :channel_info} =
                 ChannelManager.start_channel(root, "private:info", params)

        assert Client.get_state(root, :joined_channels)["private:info"].pid == channel
        entries = :sys.get_state(store).channels
        assert map_size(entries) == 1

        assert {:error, :private_callback_failure} =
                 ChannelManager.start_channel(root, "private:failed", params, FailedStartChannel)

        assert Process.alive?(store)
        assert :sys.get_state(store).channels == entries
        monitor = Process.monitor(channel)
        send(channel, {:"$gen_call", {self(), make_ref()}, {:private_call, @sentinel}})
        assert_receive {:DOWN, ^monitor, :process, ^channel, :private_callback_failure}

        replacement =
          await(fn ->
            case Registry.lookup(registry, "private:info") do
              [{pid, _}] when pid != channel -> pid
              _ -> nil
            end
          end)

        assert :sys.get_state(replacement).params == params
        assert map_size(:sys.get_state(store).channels) == 1
        assert :ok = Channel.leave(replacement)
        await(fn -> :sys.get_state(store).channels == %{} end)
      end)

    refute log =~ @sentinel
    assert_private(reports([]))
  end

  defp options(name) do
    [
      name: name,
      auto_connect: false,
      reconnect: false,
      transport_opts: [ssl: [keyfile: @sentinel]],
      headers: [{"authorization", @sentinel}]
    ]
  end

  defp assert_private(term) do
    refute inspect(term, limit: :infinity) =~ @sentinel
    refute :erlang.term_to_binary(term) =~ @sentinel
  end

  defp reports(acc) do
    receive do
      {:supervisor_log, event} -> reports([event | acc])
    after
      0 -> acc
    end
  end

  defp await(function, remaining \\ 100)
  defp await(_function, 0), do: flunk("client lifecycle did not settle")

  defp await(function, remaining) do
    case function.() do
      value when value in [nil, false] ->
        Process.sleep(10)
        await(function, remaining - 1)

      value ->
        value
    end
  end
end
