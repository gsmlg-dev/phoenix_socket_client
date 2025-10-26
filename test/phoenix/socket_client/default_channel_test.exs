defmodule Phoenix.SocketClient.DefaultChannelTest do
  use ExUnit.Case, async: false

  alias Phoenix.SocketClient

  defmodule MyDefaultChannel do
    use Phoenix.SocketClient.Channel

    @impl true
    def handle_message(event, payload, state) do
      IO.puts("MyDefaultChannel received: event=#{event}, payload=#{inspect(payload)}")
      send(state.caller, {:my_channel, event, payload})
      {:noreply, state}
    end
  end

  defp get_port do
    Application.get_env(:phoenix_socket_client_test, :port, 5807)
  end

  defp get_socket_config do
    port = get_port()

    [
      url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
      serializer: Jason,
      reconnect_interval: 10
    ]
  end

  setup_all do
    Application.ensure_all_started(:bandit)
    Application.ensure_all_started(:phoenix)
    Application.ensure_all_started(:jason)
    :ok
  end

  setup do
    start_supervised({Registry, keys: :unique, name: Registry.Connection})
    :ok
  end

  @tag :skip
  test "uses default channel module and params" do
    name = :"default_channel_test_#{System.unique_integer([:positive])}"

    config =
      get_socket_config()
      |> Keyword.put(:name, name)
      |> Keyword.put(:default_channel_module, MyDefaultChannel)
      |> Keyword.put(:default_channel_params, %{"default" => "param"})

    {:ok, sup} = SocketClient.start_link(config)

    wait_for_socket(name)

    {:ok, _response, channel} = SocketClient.Channel.join(sup, "test:topic")
    SocketClient.Channel.push(channel, "test_event", %{"foo" => "bar"})
    assert_receive {:my_channel, "test_event", %{"foo" => "bar"}}, 5_000
  end

  defp wait_for_socket(socket_name, retries \\ 300) do
    if retries == 0 do
      false
    else
      case SocketClient.connected?(socket_name) do
        true ->
          true

        false ->
          :timer.sleep(100)
          wait_for_socket(socket_name, retries - 1)
      end
    end
  end
end
