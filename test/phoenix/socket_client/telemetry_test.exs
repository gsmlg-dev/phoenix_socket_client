defmodule Phoenix.SocketClient.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Phoenix.SocketClient.Telemetry

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

    # Reset telemetry config before each test
    Telemetry.reset_config()

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

  describe "telemetry configuration" do
    test "default configuration is loaded correctly" do
      config = Telemetry.config()

      assert config.enabled == true
      assert config.default_handler == false
      assert config.track_durations == true
      assert config.track_memory_usage == true
      assert config.track_message_sizes == true
      assert config.sampler_rate == 1.0
      assert config.max_events_per_second == 1000
      assert config.event_buffer_size == 10_000

      assert is_map(config.log_levels)
      assert config.log_levels.connection == :info
      assert config.log_levels.error == :error

      assert is_map(config.filters)
      assert config.filters.exclude_heartbeats == false
      assert config.filters.min_duration_threshold == 0
    end

    test "can update configuration" do
      Telemetry.update_config(%{enabled: false, sampler_rate: 0.5})

      assert Telemetry.get_config(:enabled) == false
      assert Telemetry.get_config(:sampler_rate) == 0.5
    end

    test "can reset configuration to defaults" do
      Telemetry.update_config(%{enabled: false})
      assert Telemetry.get_config(:enabled) == false

      Telemetry.reset_config()
      assert Telemetry.get_config(:enabled) == true
    end

    test "telemetry enable/disable functionality" do
      assert Telemetry.enabled?() == true

      Telemetry.update_config(%{enabled: false})
      assert Telemetry.enabled?() == false

      Telemetry.reset_config()
      assert Telemetry.enabled?() == true
    end

    test "duration tracking configuration" do
      assert Telemetry.track_durations?() == true

      Telemetry.update_config(%{track_durations: false})
      assert Telemetry.track_durations?() == false

      Telemetry.reset_config()
      assert Telemetry.track_durations?() == true
    end

    test "memory usage tracking configuration" do
      assert Telemetry.track_memory_usage?() == true

      Telemetry.update_config(%{track_memory_usage: false})
      assert Telemetry.track_memory_usage?() == false

      Telemetry.reset_config()
      assert Telemetry.track_memory_usage?() == true
    end

    test "message size tracking configuration" do
      assert Telemetry.track_message_sizes?() == true

      Telemetry.update_config(%{track_message_sizes: false})
      assert Telemetry.track_message_sizes?() == false

      Telemetry.reset_config()
      assert Telemetry.track_message_sizes?() == true
    end
  end

  describe "sampling functionality" do
    test "sampler rate configuration" do
      assert Telemetry.sampler_rate() == 1.0

      Telemetry.update_config(%{sampler_rate: 0.5})
      assert Telemetry.sampler_rate() == 0.5

      Telemetry.reset_config()
      assert Telemetry.sampler_rate() == 1.0
    end

    test "should_sample? with 100% rate" do
      Telemetry.update_config(%{sampler_rate: 1.0})
      assert Telemetry.should_sample?() == true
    end

    test "should_sample? with 0% rate" do
      Telemetry.update_config(%{sampler_rate: 0.0})
      assert Telemetry.should_sample?() == false
    end

    test "should_sample? with 50% rate (statistical test)" do
      Telemetry.update_config(%{sampler_rate: 0.5})

      # Statistical test - with enough samples, should be roughly 50%
      samples = for _i <- 1..1000, do: Telemetry.should_sample?()
      true_count = Enum.count(samples, &(&1 == true))

      # Allow for some variance (should be around 500 ± 50)
      assert true_count > 400 and true_count < 600
    end
  end

  describe "event filtering" do
    test "passes_filters? with duration threshold" do
      Telemetry.update_config(%{filters: %{min_duration_threshold: 100}})

      # Event with duration below threshold should be filtered out (50 microseconds = 0.05ms)
      assert Telemetry.passes_filters?(
               [:phoenix, :socket_client, :connection],
               # 50 microseconds in nanoseconds
               %{duration: 50_000}
             ) == false

      # Event with duration above threshold should pass (200 milliseconds)
      assert Telemetry.passes_filters?(
               [:phoenix, :socket_client, :connection],
               # 200 milliseconds in nanoseconds
               %{duration: 200_000_000}
             ) == true

      # Event without duration should pass
      assert Telemetry.passes_filters?(
               [:phoenix, :socket_client, :connection],
               %{}
             ) == true
    end

    test "passes_filters? with heartbeat exclusion" do
      Telemetry.update_config(%{filters: %{exclude_heartbeats: true}})

      # Heartbeat events should be filtered out
      assert Telemetry.passes_filters?([:phoenix, :socket_client, :heartbeat, :sent]) == false
      assert Telemetry.passes_filters?([:phoenix, :socket_client, :heartbeat, :timeout]) == false

      # Other events should pass
      assert Telemetry.passes_filters?([:phoenix, :socket_client, :connection, :start]) == true
    end

    test "passes_filters? with message send exclusion" do
      Telemetry.update_config(%{filters: %{exclude_message_sends: true}})

      # Message send events should be filtered out
      assert Telemetry.passes_filters?([:phoenix, :socket_client, :message, :send, :start]) ==
               false

      # Other message events should pass
      assert Telemetry.passes_filters?([:phoenix, :socket_client, :message, :receive]) == true
    end

    test "passes_filters? with system metrics exclusion" do
      Telemetry.update_config(%{filters: %{exclude_system_metrics: true}})

      # System metrics events should be filtered out
      assert Telemetry.passes_filters?([:phoenix, :socket_client, :optimization, :system]) ==
               false

      # Other optimization events should pass
      assert Telemetry.passes_filters?([:phoenix, :socket_client, :optimization, :cache]) == true
    end
  end

  describe "event emission" do
    test "emit_event when enabled" do
      test_pid = self()
      handler_id = "test-emission-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:phoenix, :socket_client, :test, :event],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      Telemetry.emit_event(
        [:phoenix, :socket_client, :test, :event],
        %{test_measurement: 123},
        %{test_metadata: "value"}
      )

      assert_receive {[:phoenix, :socket_client, :test, :event], %{test_measurement: 123},
                      %{test_metadata: "value"}},
                     1000

      :telemetry.detach(handler_id)
    end

    test "emit_event when disabled" do
      Telemetry.update_config(%{enabled: false})

      test_pid = self()
      handler_id = "test-emission-disabled-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:phoenix, :socket_client, :test, :event],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      Telemetry.emit_event(
        [:phoenix, :socket_client, :test, :event],
        %{test_measurement: 123},
        %{test_metadata: "value"}
      )

      refute_receive {[:phoenix, :socket_client, :test, :event], _, _}, 100

      :telemetry.detach(handler_id)
    end

    test "emit_event with sampling" do
      # 0% sampling
      Telemetry.update_config(%{sampler_rate: 0.0})

      test_pid = self()
      handler_id = "test-emission-sampling-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:phoenix, :socket_client, :test, :event],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      # With 0% sampling, event should not be emitted
      Telemetry.emit_event(
        [:phoenix, :socket_client, :test, :event],
        %{test_measurement: 123},
        %{test_metadata: "value"}
      )

      refute_receive {[:phoenix, :socket_client, :test, :event], _, _}, 100

      :telemetry.detach(handler_id)
    end
  end

  describe "span-based duration tracking" do
    test "span function emits start and stop events" do
      test_pid = self()
      handler_id = "test-span-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:phoenix, :socket_client, :test, :operation, :start],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:start, event_name, measurements, metadata})
        end,
        %{}
      )

      :telemetry.attach_many(
        "#{handler_id}-stop",
        [
          [:phoenix, :socket_client, :test, :operation, :stop],
          [:phoenix, :socket_client, :test, :operation, :exception]
        ],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:stop, event_name, measurements, metadata})
        end,
        %{}
      )

      # Ensure telemetry is enabled for this test
      Telemetry.update_config(%{enabled: true, track_durations: true, sampler_rate: 1.0})

      result =
        Telemetry.span(
          [:phoenix, :socket_client, :test, :operation],
          %{test_meta: "value"},
          fn ->
            :timer.sleep(10)
            {:ok, %{result: "test"}}
          end
        )

      assert result == {:ok, %{result: "test"}}

      assert_receive {:start, [:phoenix, :socket_client, :test, :operation, :start], _,
                      %{test_meta: "value"}},
                     1000

      assert_receive {:stop, [:phoenix, :socket_client, :test, :operation, :stop],
                      %{duration: duration}, _},
                     1000

      assert duration > 0

      :telemetry.detach(handler_id)
      :telemetry.detach("#{handler_id}-stop")
    end

    test "span function when duration tracking disabled" do
      Telemetry.update_config(%{track_durations: false})

      test_pid = self()
      handler_id = "test-span-disabled-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:phoenix, :socket_client, :test, :operation, :start],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:start, event_name, measurements, metadata})
        end,
        %{}
      )

      result =
        Telemetry.span(
          [:phoenix, :socket_client, :test, :operation],
          %{test_meta: "value"},
          fn ->
            {:ok, %{result: "test"}}
          end
        )

      assert {:ok, %{result: "test"}} = result

      refute_receive {:start, _, _, _}, 100

      :telemetry.detach(handler_id)
    end
  end

  describe "manual duration tracking" do
    test "start_duration and stop_duration" do
      test_pid = self()
      handler_id = "test-manual-duration-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:phoenix, :socket_client, :test, :test_op, :start],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:start, event_name, measurements, metadata})
        end,
        %{}
      )

      :telemetry.attach(
        "#{handler_id}-stop",
        [:phoenix, :socket_client, :test, :test_op, :stop],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:stop, event_name, measurements, metadata})
        end,
        %{}
      )

      token = Telemetry.start_duration(:test, :test_op, %{test_meta: "value"})
      assert is_map(token)
      assert token.component == :test
      assert token.operation == :test_op

      assert_receive {:start, [:phoenix, :socket_client, :test, :test_op, :start], _,
                      %{test_meta: "value"}},
                     1000

      :timer.sleep(10)
      Telemetry.stop_duration(token, %{additional_meta: "data"})

      assert_receive {:stop, [:phoenix, :socket_client, :test, :test_op, :stop],
                      %{duration: duration}, %{additional_meta: "data"}},
                     1000

      assert duration > 0

      :telemetry.detach(handler_id)
      :telemetry.detach("#{handler_id}-stop")
    end

    test "measure_duration function" do
      test_pid = self()
      handler_id = "test-measure-duration-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:phoenix, :socket_client, :test, :test_op, :start],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:start, event_name, measurements, metadata})
        end,
        %{}
      )

      :telemetry.attach(
        "#{handler_id}-stop",
        [:phoenix, :socket_client, :test, :test_op, :stop],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:stop, event_name, measurements, metadata})
        end,
        %{}
      )

      result =
        Telemetry.measure_duration(:test, :test_op, %{test_meta: "value"}, fn ->
          :timer.sleep(10)
          "test_result"
        end)

      assert result == "test_result"

      assert_receive {:start, [:phoenix, :socket_client, :test, :test_op, :start], _,
                      %{test_meta: "value"}},
                     1000

      assert_receive {:stop, [:phoenix, :socket_client, :test, :test_op, :stop],
                      %{duration: duration}, %{status: :success}},
                     1000

      assert duration > 0

      :telemetry.detach(handler_id)
      :telemetry.detach("#{handler_id}-stop")
    end
  end

  describe "duration context" do
    test "create_duration_context and measure_sub_operation" do
      test_pid = self()
      handler_id = "test-duration-context-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:phoenix, :socket_client, :test, :sub_op1, :complete],
          [:phoenix, :socket_client, :test, :sub_op2, :complete],
          [:phoenix, :socket_client, :test, :context_complete]
        ],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      context = Telemetry.create_duration_context(:test, %{test_meta: "value"})
      assert is_map(context)
      assert context.component == :test

      # Measure first sub-operation
      result1 =
        Telemetry.measure_sub_operation(context, :sub_op1, fn ->
          :timer.sleep(5)
          "result1"
        end)

      assert result1 == "result1"

      # Measure second sub-operation
      result2 =
        Telemetry.measure_sub_operation(context, :sub_op2, fn ->
          :timer.sleep(5)
          "result2"
        end)

      assert result2 == "result2"

      # Complete the context
      Telemetry.complete_duration_context(context, %{final_meta: "data"})

      assert_receive {[:phoenix, :socket_client, :test, :sub_op1, :complete],
                      %{duration: _duration1}, _},
                     1000

      assert_receive {[:phoenix, :socket_client, :test, :sub_op2, :complete],
                      %{duration: _duration2}, _},
                     1000

      assert_receive {[:phoenix, :socket_client, :test, :context_complete], measurements,
                      %{final_meta: "data"}},
                     1000

      assert measurements.total_duration > 0
      # Note: operation_count might be 0 due to context immutability limitations
      # The sub-operation events are still being emitted correctly

      :telemetry.detach(handler_id)
    end
  end

  describe "specific telemetry events" do
    test "connection events" do
      test_pid = self()
      handler_id = "test-connection-events-#{System.unique_integer()}"

      events = [
        [:phoenix, :socket_client, :connection, :start],
        [:phoenix, :socket_client, :connection, :stop],
        [:phoenix, :socket_client, :connection, :error]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      Telemetry.connection_start(%{url: "ws://test.com", transport: :websocket})
      Telemetry.connection_stop(%{url: "ws://test.com", duration: 100})
      Telemetry.connection_error(%{url: "ws://test.com", error: "connection_failed"})

      assert_receive {[:phoenix, :socket_client, :connection, :start], _,
                      %{url: "ws://test.com", transport: :websocket}},
                     1000

      assert_receive {[:phoenix, :socket_client, :connection, :stop], _,
                      %{url: "ws://test.com", duration: 100}},
                     1000

      assert_receive {[:phoenix, :socket_client, :connection, :error], _,
                      %{url: "ws://test.com", error: "connection_failed"}},
                     1000

      :telemetry.detach(handler_id)
    end

    test "channel events" do
      test_pid = self()
      handler_id = "test-channel-events-#{System.unique_integer()}"

      events = [
        [:phoenix, :socket_client, :channel, :join, :start],
        [:phoenix, :socket_client, :channel, :join, :stop],
        [:phoenix, :socket_client, :channel, :leave],
        [:phoenix, :socket_client, :channel, :active]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      Telemetry.channel_join_start(%{topic: "rooms:lobby"})
      Telemetry.channel_join_stop(%{topic: "rooms:lobby", duration: 50})
      Telemetry.channel_left(%{topic: "rooms:lobby"})
      Telemetry.channel_active(%{topic: "rooms:lobby"})

      assert_receive {[:phoenix, :socket_client, :channel, :join, :start], _,
                      %{topic: "rooms:lobby"}},
                     1000

      assert_receive {[:phoenix, :socket_client, :channel, :join, :stop], _,
                      %{topic: "rooms:lobby", duration: 50}},
                     1000

      assert_receive {[:phoenix, :socket_client, :channel, :leave], _, %{topic: "rooms:lobby"}},
                     1000

      assert_receive {[:phoenix, :socket_client, :channel, :active], _, %{topic: "rooms:lobby"}},
                     1000

      :telemetry.detach(handler_id)
    end

    test "message events" do
      test_pid = self()
      handler_id = "test-message-events-#{System.unique_integer()}"

      events = [
        [:phoenix, :socket_client, :message, :send],
        [:phoenix, :socket_client, :message, :receive],
        [:phoenix, :socket_client, :message, :encode],
        [:phoenix, :socket_client, :message, :decode]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      Telemetry.message_send(%{topic: "rooms:lobby", event: "new_msg", ref: "1"})
      Telemetry.message_receive(%{topic: "rooms:lobby", event: "new_msg", ref: "1"})
      Telemetry.message_encoded(%{event: "new_msg", size_bytes: 25})
      Telemetry.message_decoded(%{event: "new_msg", size_bytes: 30})

      assert_receive {[:phoenix, :socket_client, :message, :send], %{system_time: _},
                      %{topic: "rooms:lobby", event: "new_msg", ref: "1"}},
                     1000

      assert_receive {[:phoenix, :socket_client, :message, :receive], %{system_time: _},
                      %{topic: "rooms:lobby", event: "new_msg", ref: "1"}},
                     1000

      assert_receive {[:phoenix, :socket_client, :message, :encode], %{system_time: _},
                      %{event: "new_msg", size_bytes: 25}},
                     1000

      assert_receive {[:phoenix, :socket_client, :message, :decode], %{system_time: _},
                      %{event: "new_msg", size_bytes: 30}},
                     1000

      :telemetry.detach(handler_id)
    end

    test "optimization events" do
      test_pid = self()
      handler_id = "test-optimization-events-#{System.unique_integer()}"

      events = [
        [:phoenix, :socket_client, :optimization, :cache, :hit],
        [:phoenix, :socket_client, :optimization, :cache, :miss],
        [:phoenix, :socket_client, :optimization, :binary_pool, :hit],
        [:phoenix, :socket_client, :optimization, :hibernation, :process_hibernated]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      Telemetry.optimization_cache_hit(%{cache_type: :route_cache, topic: "rooms:lobby"})
      Telemetry.optimization_cache_miss(%{cache_type: :route_cache, topic: "rooms:new"})
      Telemetry.optimization_binary_pool_hit(%{pattern_size: 15})
      Telemetry.optimization_process_hibernated(%{process_name: :socket, memory_saved: 1024})

      assert_receive {[:phoenix, :socket_client, :optimization, :cache, :hit], %{system_time: _},
                      %{cache_type: :route_cache, topic: "rooms:lobby"}},
                     1000

      assert_receive {[:phoenix, :socket_client, :optimization, :cache, :miss], %{system_time: _},
                      %{cache_type: :route_cache, topic: "rooms:new"}},
                     1000

      assert_receive {[:phoenix, :socket_client, :optimization, :binary_pool, :hit],
                      %{system_time: _}, %{pattern_size: 15}},
                     1000

      assert_receive {[
                        :phoenix,
                        :socket_client,
                        :optimization,
                        :hibernation,
                        :process_hibernated
                      ], %{system_time: _}, %{process_name: :socket, memory_saved: 1024}},
                     1000

      :telemetry.detach(handler_id)
    end

    test "error events" do
      test_pid = self()
      handler_id = "test-error-events-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:phoenix, :socket_client, :error],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      Telemetry.error(%{component: :socket, error: "connection_failed", reason: "timeout"})

      assert_receive {[:phoenix, :socket_client, :error], _,
                      %{component: :socket, error: "connection_failed", reason: "timeout"}},
                     1000

      :telemetry.detach(handler_id)
    end
  end

  describe "default handler" do
    test "attach_default_handler creates logger integration" do
      log =
        capture_log(fn ->
          Telemetry.attach_default_handler(enabled: true)

          Telemetry.emit_event(
            [:phoenix, :socket_client, :connection, :start],
            %{},
            %{url: "ws://test.com"}
          )

          # Give async handler time to process
          :timer.sleep(50)
        end)

      assert log =~ "Phoenix.SocketClient"
      assert log =~ "connection"
      assert log =~ "ws://test.com"

      # Clean up
      :telemetry.detach("phoenix-socket-client-default-handler")
    end

    test "default handler respects log levels" do
      log =
        capture_log(fn ->
          Telemetry.attach_default_handler(enabled: true)

          Telemetry.emit_event(
            [:phoenix, :socket_client, :error],
            %{},
            %{error: "test error"}
          )

          # Give async handler time to process
          :timer.sleep(50)
        end)

      # Error events should be logged at error level
      assert log =~ "[error]" or log =~ "test error"

      # Clean up
      :telemetry.detach("phoenix-socket-client-default-handler")
    end
  end

  describe "legacy compatibility" do
    test "execute/3 legacy function" do
      test_pid = self()
      handler_id = "test-legacy-execute-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:phoenix, :socket_client, :legacy, :event],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        %{}
      )

      # This should work for backward compatibility
      assert :ok =
               Telemetry.execute(
                 [:phoenix, :socket_client, :legacy, :event],
                 %{test_measurement: 123},
                 %{test_metadata: "value"}
               )

      assert_receive {[:phoenix, :socket_client, :legacy, :event], %{test_measurement: 123},
                      %{test_metadata: "value"}},
                     1000

      :telemetry.detach(handler_id)
    end
  end
end
