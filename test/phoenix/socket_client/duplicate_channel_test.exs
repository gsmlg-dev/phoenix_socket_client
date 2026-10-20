defmodule Phoenix.SocketClient.DuplicateChannelTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Phoenix.SocketClient, as: Client
  alias Phoenix.SocketClient.{Channel, ChannelManager}

  defmodule RegisteredChannel do
    use Phoenix.SocketClient.Channel

    @impl true
    def handle_message(_event, _payload, state), do: {:noreply, state}
  end

  defmodule RegistrationFailureChannel do
    use Phoenix.SocketClient.Channel

    @impl true
    def init({identity, private}) do
      send(self(), {:private, private})
      {:stop, {:already_registered, identity}}
    end

    @impl true
    def handle_message(_event, _payload, state), do: {:noreply, state}
  end

  defmodule ReplyTransport do
    @behaviour Phoenix.SocketClient.Transport

    @impl true
    def open(_url, opts) do
      sender = Keyword.fetch!(opts, :sender)
      owner = Keyword.fetch!(opts, :owner)

      {:ok,
       spawn(fn ->
         send(sender, {:connected, self()})
         loop(sender, owner)
       end)}
    end

    @impl true
    def close(pid) do
      send(pid, :close)
      :ok
    end

    defp loop(sender, owner) do
      receive do
        {:send, encoded} ->
          [join_ref, ref, topic, event, payload] = JSON.decode!(encoded)
          send(owner, {:outbound, topic, event, payload})
          reply = [join_ref, ref, topic, "phx_reply", %{"status" => "ok", "response" => payload}]
          send(sender, {:receive, JSON.encode!(reply)})
          loop(sender, owner)

        :close ->
          :ok
      end
    end
  end

  test "a duplicate dynamic child fails initialization with the registered PID" do
    registry = unique_name()
    start_supervised!({Registry, keys: :unique, name: registry})
    manager = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    spec = {RegisteredChannel, {nil, nil, "host_agent:fixture", %{}, registry}}

    assert {:ok, first} = DynamicSupervisor.start_child(manager, spec)

    assert {:error, {:already_registered, ^first}} =
             DynamicSupervisor.start_child(manager, spec)

    assert Process.alive?(first)
    assert Registry.lookup(registry, "host_agent:fixture") == [{first, first}]
    assert DynamicSupervisor.count_children(manager).active == 1
  end

  test "simultaneous initializations leave only one registered child" do
    registry = unique_name()
    start_supervised!({Registry, keys: :unique, name: registry})
    manager = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    spec = {RegisteredChannel, {nil, nil, "host_agent:concurrent", %{}, registry}}

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> DynamicSupervisor.start_child(manager, spec) end) end)
      |> Enum.map(&Task.await/1)

    assert [{:ok, first}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &(&1 == {:error, {:already_registered, first}})) == 7
    assert Process.alive?(first)
    assert Registry.lookup(registry, "host_agent:concurrent") == [{first, first}]
    assert DynamicSupervisor.count_children(manager).active == 1
  end

  test "registration failure identities do not expose pending private messages in crash reports" do
    owner = self()
    private = "DUPLICATE_CHANNEL_PRIVATE_SENTINEL"
    manager = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    observer = fn event, pid ->
      send(pid, {:registration_log, event})
      :ignore
    end

    :ok = :logger.add_primary_filter(__MODULE__, {observer, owner})
    on_exit(fn -> :logger.remove_primary_filter(__MODULE__) end)

    log =
      capture_log(fn ->
        assert {:error, {:already_registered, ^owner}} =
                 DynamicSupervisor.start_child(
                   manager,
                   {RegistrationFailureChannel, {owner, private}}
                 )

        assert {:error, :private_callback_failure} =
                 DynamicSupervisor.start_child(
                   manager,
                   {RegistrationFailureChannel, {private, private}}
                 )

        Logger.flush()
      end)

    refute log =~ private
    refute :erlang.term_to_binary(registration_logs([])) =~ private
    assert DynamicSupervisor.count_children(manager).active == 0
  end

  test "public duplicate joins preserve the existing channel without another wire join" do
    root =
      start_supervised!(
        {Client,
         name: unique_name(),
         url: "ws://example.invalid/socket/websocket",
         auto_connect: false,
         transport: ReplyTransport,
         transport_opts: [owner: self()]}
      )

    assert :ok = Client.connect(root)
    assert_connected(root)
    params = %{"owner" => "original"}
    assert {:ok, ^params, first} = Channel.join(root, "test:duplicate", params)
    assert_receive {:outbound, "test:duplicate", "phx_join", ^params}

    assert {:error, {:already_started, ^first}} =
             Channel.join(root, "test:duplicate", %{"owner" => "duplicate"})

    assert {:error, {:already_started, ^first}} =
             ChannelManager.start_channel(root, "test:duplicate", %{})

    manager = Client.get_process_pid(root, :channel_manager)
    assert DynamicSupervisor.count_children(manager).active == 1
    assert ChannelManager.channel_pid(root, "test:duplicate") == first
    assert Process.alive?(first)

    assert %{pid: ^first, status: :joined, params: ^params} =
             Client.get_state(root, :joined_channels)["test:duplicate"]

    assert {:ok, %{"still" => "usable"}} = Channel.push(first, "ping", %{"still" => "usable"})
    assert_receive {:outbound, "test:duplicate", "ping", %{"still" => "usable"}}
    refute_receive {:outbound, "test:duplicate", "phx_join", _}, 100
  end

  defp assert_connected(root, attempts \\ 100)
  defp assert_connected(root, 0), do: assert(Client.connected?(root))

  defp assert_connected(root, attempts) do
    unless Client.connected?(root) do
      Process.sleep(10)
      assert_connected(root, attempts - 1)
    end
  end

  defp registration_logs(events) do
    receive do
      {:registration_log, event} -> registration_logs([event | events])
    after
      0 -> events
    end
  end

  defp unique_name, do: :"duplicate_channel_#{System.unique_integer([:positive])}"
end
