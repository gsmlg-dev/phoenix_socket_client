defmodule Phoenix.SocketClient.TelemetryTest do
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

  describe "telemetry events" do
    test "emits connection duration event" do
      name = :"telemetry_conn_duration_#{System.unique_integer([:positive])}"

      config =
        get_socket_config() |> Keyword.put(:name, name) |> Keyword.put(:auto_connect, false)

      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      handler_id = "test-handler-#{System.unique_integer()}"
      test_pid = self()
      :telemetry.attach(
        handler_id,
        [:phoenix_socket_client, :socket],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      Phoenix.SocketClient.connect(sup_pid)
      wait_for_socket(name)

      assert_receive {[:phoenix_socket_client, :socket], %{duration: duration},
                      %{action: :connection_duration, pid: _, url: _, timestamp: _}},
                     5_000

      assert is_integer(duration) and duration > 0

      :telemetry.detach(handler_id)
    end

    test "emits channel join duration event" do
      name = :"telemetry_join_duration_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)
      wait_for_socket(name)

      handler_id = "test-handler-#{System.unique_integer()}"
      test_pid = self()
      :telemetry.attach(
        handler_id,
        [:phoenix_socket_client, :channel],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      {:ok, _, _channel_pid} = Phoenix.SocketClient.Channel.join(sup_pid, "topic:status")
      Process.sleep(100)

      assert_receive {[:phoenix_socket_client, :channel], %{duration: duration},
                      %{action: :join_duration, pid: _, topic: "topic:status", timestamp: _}},
                     5_000

      assert is_integer(duration) and duration > 0

      :telemetry.detach(handler_id)
    end

    test "emits channel leave duration event" do
      name = :"telemetry_leave_duration_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)
      wait_for_socket(name)

      {:ok, _, channel_pid} = Phoenix.SocketClient.Channel.join(sup_pid, "topic:status")
      Process.sleep(100)

      handler_id = "test-handler-#{System.unique_integer()}"
      test_pid = self()
      :telemetry.attach(
        handler_id,
        [:phoenix_socket_client, :channel],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      :ok = Phoenix.SocketClient.Channel.leave(channel_pid)
      Process.sleep(100)

      assert_receive {[:phoenix_socket_client, :channel], %{duration: duration},
                      %{action: :leave_duration, pid: _, topic: "topic:status", timestamp: _}},
                     5_000

      assert is_integer(duration) and duration > 0

      :telemetry.detach(handler_id)
    end
  end
end
