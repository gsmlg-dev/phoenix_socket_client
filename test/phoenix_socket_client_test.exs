defmodule PhoenixSocketClientTest do
  use ExUnit.Case, async: false


  alias PhoenixSocketClient.{Socket, Channel, Message}


  @port 5807

  @socket_config [
    url: "ws://127.0.0.1:#{@port}/ws/admin/websocket",
    serializer: Jason,
    reconnect_interval: 10
  ]

  setup_all do
    Application.ensure_all_started(:bandit)
    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:jason)
    :ok
  end

  setup do
    start_supervised({Registry, keys: :unique, name: Registry.Connection})
    start_supervised({PhoenixSocketClient, name: PhoenixSocketClient})
    :ok
  end

  test "socket can join a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    assert {:ok, _, _channel} = Channel.join(name, "rooms:admin-lobby")
  end

  test "socket cannot join more than one channel of the same topic" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    assert {:ok, _, _channel} = Channel.join(name, "rooms:admin-lobby")
    assert {:error, {:already_started, _}} = Channel.join(name, "rooms:admin-lobby")
  end

  test "socket can join a channel and receive a reply" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    message = %{"foo" => "bar"}
    assert {:ok, ^message, _channel} = Channel.join(name, "rooms:reply", message)
  end

  test "return an error if socket is down" do
    assert {:error, :socket_not_started} = Channel.join(nil, "rooms:any")
  end

  test "socket can join a channel with params" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    user_id = "123"
    assert {:ok, _, _} = Channel.join(name, "rooms:admin-lobby", %{user: user_id})
    assert_receive %Message{event: "user:entered", payload: %{"user" => ^user_id}}
  end

  test "socket can leave a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert :ok = Channel.leave(channel)
  end

  test "client can push to a channel" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert {:ok, %{"test" => "test"}} = Channel.push(channel, "new:msg", %{test: :test})
  end

  test "join timeouts" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:error, :timeout} = Channel.join(name, "rooms:join_timeout", %{}, 1)
  end

  test "push timeouts" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert catch_exit(Channel.push(channel, "foo:bar", %{}, 500))
  end

  test "push async" do
    name = :"socket_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      PhoenixSocketClient.start_link(Keyword.put(@socket_config, :id, name))

    wait_for_socket(name)
    {:ok, _, channel} = Channel.join(name, "rooms:admin-lobby")
    assert :ok = Channel.push_async(channel, "foo:bar", %{})
  end

  test "socket params can be sent" do
    name = :"socket_#{System.unique_integer([:positive])}"

    opts =
      @socket_config
      |> Keyword.put(:id, name)
      |> Keyword.put(:params, %{"reject" => true})
      |> Keyword.put(:caller, self())

    {:ok, _pid} = PhoenixSocketClient.start_link(opts)
    :timer.sleep(100)
    refute Socket.connected?(name)
  end

  test "socket params can be set in url" do
    name = :"socket_#{System.unique_integer([:positive])}"

    opts = [
      url: "ws://127.0.0.1:#{@port}/ws/admin/websocket?reject=true",
      serializer: Jason,
      caller: self(),
      id: name
    ]

    {:ok, _pid} = PhoenixSocketClient.start_link(opts)
    :timer.sleep(100)
    refute Socket.connected?(name)
  end

  test "pass extra headers" do
    name = :"socket_#{System.unique_integer([:positive])}"

    config =
      @socket_config
      |> Keyword.put(:id, name)
      |> Keyword.put(:headers, [{"x-extra", "value"}])

    {:ok, _pid} = PhoenixSocketClient.start_link(config)
    wait_for_socket(name)
    {:ok, headers, _channel} = Channel.join(name, "rooms:headers")
    assert %{"x-extra" => "value"} = headers
  end

  defp wait_for_socket(socket_name, retries \\ 500) do
    if retries == 0 do
      raise "Socket did not connect in time"
    end

    # Get the supervisor pid for the socket
    supervisor_pid = Process.whereis(socket_name)

    if supervisor_pid do
      # Find the socket process within the supervisor
      children = Supervisor.which_children(supervisor_pid)

      case Enum.find(children, fn {id, _, _, _} -> id == :socket end) do
        {:socket, socket_pid, _, _} ->
          try do
            case GenServer.call(socket_pid, :get_status, 1000) do
              :connected ->
                :ok

              _status ->
                :timer.sleep(100)
                wait_for_socket(socket_name, retries - 1)
            end
          catch
            :exit, _reason ->
              :timer.sleep(100)
              wait_for_socket(socket_name, retries - 1)
          end

        _ ->
          :timer.sleep(100)
          wait_for_socket(socket_name, retries - 1)
      end
    else
      case Socket.connected?(socket_name) do
        true ->
          :ok

        false ->
          :timer.sleep(100)
          wait_for_socket(socket_name, retries - 1)
      end
    end
  end

end
