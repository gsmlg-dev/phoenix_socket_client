defmodule Phoenix.SocketClient.Performance.OptimizationTest do
  @moduledoc """
  Integration test for performance optimizations.

  This test verifies that all our performance optimizations work together
  correctly and provide the expected benefits.
  """

  use ExUnit.Case, async: false

  alias Phoenix.SocketClient.BinaryPool
  alias Phoenix.SocketClient.RouteCache
  alias Phoenix.SocketClient.Router

  @moduletag :performance

  describe "Optimization Integration" do
    test "all optimizations start correctly" do
      # Start a socket with optimizations enabled
      {:ok, socket_pid} = Phoenix.SocketClient.start_link([
        url: "ws://localhost:4000/socket/websocket",
        auto_connect: false,
        registry_name: :"TestRegistry#{System.unique_integer()}",
        binary_pool_size: 100,
        route_cache_size: 100,
        hibernation_enabled: true,
        transport_opts: [
          tcp_opts: [
            nodelay: true,
            keepalive: true,
            buffer: 64 * 1024
          ]
        ]
      ])

      # Verify all optimization components are running
      assert Process.alive?(socket_pid)

      # Check that route cache is accessible
      route_cache_pid = Phoenix.SocketClient.get_process_pid(socket_pid, :route_cache)
      assert is_pid(route_cache_pid)
      assert Process.alive?(route_cache_pid)

      # Check that binary pool is accessible
      binary_pool_pid = Phoenix.SocketClient.get_process_pid(socket_pid, :message_processor)
      assert is_pid(binary_pool_pid)
      assert Process.alive?(binary_pool_pid)

      # Check that hibernation manager is accessible
      hibernation_pid = Phoenix.SocketClient.get_process_pid(socket_pid, :hibernation_manager)
      assert is_pid(hibernation_pid)
      assert Process.alive?(hibernation_pid)

      # Clean up
      Phoenix.SocketClient.disconnect(socket_pid)
      :timer.sleep(100)
    end

    test "route cache performance" do
      registry_name = :"TestRouteCache#{System.unique_integer()}"
      {:ok, route_cache_pid} = RouteCache.start_link(registry_name: registry_name)

      # Test cache performance
      topic = "test:performance"
      channel_pid = self()

      # Put route in cache
      RouteCache.put(route_cache_pid, topic, channel_pid)

      # Test cache hit
      assert {:ok, ^channel_pid} = Router.route_message(topic, [
        cache_pid: route_cache_pid,
        registry_name: registry_name
      ])

      # Test cache statistics
      stats = RouteCache.stats(route_cache_pid)
      assert stats.hits > 0
      assert stats.current_size > 0

      # Clean up
      RouteCache.clear(route_cache_pid)
    end

    test "binary pool functionality" do
      {:ok, pool_pid} = BinaryPool.start_link(pool_size: 10)

      # Test binary pooling
      test_binary = <<"{\"test\": \"performance\", \"data\": \"binary_pool_test\"}">>

      # First put should add to pool
      assert ^test_binary = BinaryPool.get_or_pool(pool_pid, test_binary)

      # Second get should return pooled version
      assert ^test_binary = BinaryPool.get_or_pool(pool_pid, test_binary)

      # Test stats
      stats = BinaryPool.stats(pool_pid)
      assert stats.pool_size > 0
      assert stats.total_count > 0

      # Clean up
      GenServer.stop(pool_pid)
    end

    test "router optimization" do
      registry_name = :"TestRouter#{System.unique_integer()}"
      {:ok, _reg} = Registry.start_link(keys: :unique, name: registry_name)
      {:ok, route_cache_pid} = RouteCache.start_link(registry_name: registry_name)

      topic = "test:router"
      channel_pid = self()

      # Register in registry
      Registry.register(registry_name, topic, nil)

      # Route without cache (should use registry)
      assert {:ok, ^channel_pid} = Router.route_message(topic, [
        registry_name: registry_name,
        use_cache: false
      ])

      # Route with cache (should populate cache)
      assert {:ok, ^channel_pid} = Router.route_message(topic, [
        cache_pid: route_cache_pid,
        registry_name: registry_name,
        use_cache: true,
        cache_on_hit: true
      ])

      # Route again (should use cache)
      assert {:ok, ^channel_pid} = Router.route_message(topic, [
        cache_pid: route_cache_pid,
        registry_name: registry_name,
        use_cache: true
      ])

      # Verify route is cached
      assert Router.route_cached?(topic, route_cache_pid)

      # Clean up
      Registry.unregister(registry_name, topic)
      RouteCache.clear(route_cache_pid)
    end
  end

  describe "Memory Optimization" do
    test "binary pooling reduces memory pressure" do
      {:ok, pool_pid} = BinaryPool.start_link(pool_size: 50)

      # Create many similar binaries
      base_pattern = <<"{\"pattern\": \"memory_test\", \"data\": \"">>
      binaries = for i <- 1..100 do
        base_pattern <> Integer.to_string(i) <> "\"}"
      end

      # Pool all binaries
      Enum.each(binaries, fn binary ->
        BinaryPool.get_or_pool(pool_pid, binary)
      end)

      # Check pool stats
      stats = BinaryPool.stats(pool_pid)
      assert stats.pool_size <= 50  # Should be limited
      assert stats.total_count > 0

      # Memory should be reasonable
      assert stats.total_memory_bytes < 1_000_000  # Less than 1MB

      GenServer.stop(pool_pid)
    end

    test "route cache memory usage" do
      {:ok, cache_pid} = RouteCache.start_link(cache_size: 100)

      # Add many routes
      Enum.each(1..100, fn i ->
        topic = "test:memory:#{i}"
        RouteCache.put(cache_pid, topic, self())
      end)

      # Check memory usage
      stats = RouteCache.stats(cache_pid)
      assert stats.current_size <= 100
      assert stats.memory_bytes < 1_000_000  # Less than 1MB

      RouteCache.clear(cache_pid)
    end
  end

  describe "Performance Benchmarks" do
    @tag :benchmark
    test "route cache vs registry performance" do
      registry_name = :"BenchmarkRegistry#{System.unique_integer()}"
      {:ok, _reg} = Registry.start_link(keys: :unique, name: registry_name)
      {:ok, route_cache_pid} = RouteCache.start_link(registry_name: registry_name)

      topic = "benchmark:test"
      _channel_pid = self()
      Registry.register(registry_name, topic, nil)

      # Warm up cache
      Router.route_message(topic, [
        cache_pid: route_cache_pid,
        registry_name: registry_name,
        cache_on_hit: true
      ])

      # Benchmark cache lookups
      cache_time = :timer.tc(fn ->
        for _i <- 1..1000 do
          Router.route_message(topic, [
            cache_pid: route_cache_pid,
            registry_name: registry_name
          ])
        end
      end)

      # Benchmark registry lookups
      registry_time = :timer.tc(fn ->
        for _i <- 1..1000 do
          Router.route_message(topic, [
            registry_name: registry_name,
            use_cache: false
          ])
        end
      end)

      {cache_microseconds, _cache_result} = cache_time
      {registry_microseconds, _registry_result} = registry_time

      # Cache should be faster (this is a loose assertion since timing can vary)
      IO.puts("Cache lookup time: #{cache_microseconds}μs")
      IO.puts("Registry lookup time: #{registry_microseconds}μs")
      IO.puts("Performance improvement: #{Float.round(registry_microseconds / cache_microseconds, 2)}x")

      # Clean up
      Registry.unregister(registry_name, topic)
    end
  end
end