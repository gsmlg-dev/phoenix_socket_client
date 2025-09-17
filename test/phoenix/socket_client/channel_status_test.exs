defmodule Phoenix.SocketClient.ChannelStatusTest do
  use ExUnit.Case, async: false

  defp get_port do
    Application.get_env(:phoenix_socket_client_test, :port, 5807)
  end

  defp get_socket_config do
    port = get_port()
    registry_name = :"Registry.Channel_#{System.unique_integer([:positive])}"

    [
      url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
      serializer: Jason,
      reconnect_interval: 10,
      registry_name: registry_name
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

  defp wait_for_socket(socket_name, retries \\ 300) do
    if retries == 0 do
      false
    else
      case Phoenix.SocketClient.connected?(socket_name) do
        true ->
          true

        false ->
          :timer.sleep(100)
          wait_for_socket(socket_name, retries - 1)
      end
    end
  end

  describe "channel status" do
    test "transitions through joining and joined states" do
      name = :"channel_status_join_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      wait_for_socket(name)

      params = %{"foo" => "bar"}
      {:ok, _, _channel_pid} = Phoenix.SocketClient.Channel.join(sup_pid, "topic:status", params)

      # Give it a moment to join
      Process.sleep(100)

      assert %{status: :joined, params: ^params} =
               get_in(Phoenix.SocketClient.get_state(sup_pid, :joined_channels), ["topic:status"])
    end

    test "transitions to errored state on join failure" do
      name = :"channel_status_fail_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      wait_for_socket(name)

      params = %{"foo" => "bar"}
      {:error, _} = Phoenix.SocketClient.Channel.join(sup_pid, "topic:fail", params)

      Process.sleep(300)

      assert %{status: :errored, params: ^params} =
               get_in(Phoenix.SocketClient.get_state(sup_pid, :joined_channels), ["topic:fail"])
    end

    test "transitions through leaving and then is removed" do
      name = :"channel_status_leave_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      wait_for_socket(name)

      params = %{"foo" => "bar"}
      {:ok, _, channel_pid} = Phoenix.SocketClient.Channel.join(sup_pid, "topic:status", params)

      Process.sleep(100) # wait for join

      :ok = Phoenix.SocketClient.Channel.leave(channel_pid)

      Process.sleep(100) # wait for leave

      assert nil ==
               get_in(Phoenix.SocketClient.get_state(sup_pid, :joined_channels), ["topic:status"])
    end

    test "transitions to errored state on crash" do
      name = :"channel_status_crash_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      wait_for_socket(name)

      params = %{"foo" => "bar"}
      Phoenix.SocketClient.Channel.join(sup_pid, "topic:crash", params)

      Process.sleep(300)

      assert %{status: :errored, params: ^params} =
               get_in(Phoenix.SocketClient.get_state(sup_pid, :joined_channels), ["topic:crash"])
    end
  end
end
