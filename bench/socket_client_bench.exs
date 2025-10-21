defmodule Phoenix.SocketClient.Benchmarks do
  @moduledoc """
  Comprehensive benchmark suite for Phoenix.SocketClient performance analysis.

  This module provides benchmarks for:
  - Message encoding/decoding performance
  - Connection management overhead
  - Channel join/leave operations
  - Memory usage patterns
  - Concurrent operation scaling
  """

  def run_all do
    IO.puts("Running Phoenix.SocketClient benchmark suite...")

    :ok = message_benchmarks()
    :ok = connection_benchmarks()
    :ok = channel_benchmarks()
    :ok = memory_benchmarks()
    :ok = concurrency_benchmarks()

    IO.puts("Benchmark suite completed! Check benchee output for detailed results.")
    :ok
  end

  def message_benchmarks do
    IO.puts("\n=== Message Processing Benchmarks ===")

    # Test data
    small_message = %Phoenix.SocketClient.Message{
      topic: "test:lobby",
      event: "ping",
      payload: %{timestamp: System.system_time()},
      ref: "1"
    }

    medium_message = %Phoenix.SocketClient.Message{
      topic: "rooms:general",
      event: "new_message",
      payload: %{
        user: "test_user",
        message: String.duplicate("Hello world! ", 10),
        metadata: %{id: 123, type: "chat"}
      },
      ref: "2"
    }

    large_message = %Phoenix.SocketClient.Message{
      topic: "stream:data",
      event: "bulk_data",
      payload: %{
        data: List.duplicate(%{id: 1, value: String.duplicate("x", 100)}, 100),
        metadata: %{total: 100, page: 1}
      },
      ref: "3"
    }

    benchee = %Benchee.Runner{
      title: "Message Encoding Performance",
      print: [configuration: false],
      formatters: [
        {Benchee.Formatters.Console, extended_statistics: true},
        Benchee.Formatters.HTML
      ]
    }

    Benchee.run(benchee, %{
      "encode_small_message" => fn ->
        Phoenix.SocketClient.Message.encode!(Phoenix.SocketClient.Message.V2, small_message, Jason)
      end,
      "encode_medium_message" => fn ->
        Phoenix.SocketClient.Message.encode!(Phoenix.SocketClient.Message.V2, medium_message, Jason)
      end,
      "encode_large_message" => fn ->
        Phoenix.SocketClient.Message.encode!(Phoenix.SocketClient.Message.V2, large_message, Jason)
      end
    }, time: 5, memory_time: 2)

    # Benchmark decoding
    encoded_small = Phoenix.SocketClient.Message.encode!(Phoenix.SocketClient.Message.V2, small_message, Jason)
    encoded_medium = Phoenix.SocketClient.Message.encode!(Phoenix.SocketClient.Message.V2, medium_message, Jason)
    encoded_large = Phoenix.SocketClient.Message.encode!(Phoenix.SocketClient.Message.V2, large_message, Jason)

    Benchee.run(%Benchee.Runner{benchee | title: "Message Decoding Performance"}, %{
      "decode_small_message" => fn ->
        Phoenix.SocketClient.Message.decode!(Phoenix.SocketClient.Message.V2, encoded_small, Jason)
      end,
      "decode_medium_message" => fn ->
        Phoenix.SocketClient.Message.decode!(Phoenix.SocketClient.Message.V2, encoded_medium, Jason)
      end,
      "decode_large_message" => fn ->
        Phoenix.SocketClient.Message.decode!(Phoenix.SocketClient.Message.V2, encoded_large, Jason)
      end
    }, time: 5, memory_time: 2)

    :ok
  end

  def connection_benchmarks do
    IO.puts("\n=== Connection Management Benchmarks ===")

    # Benchmark process discovery
    test_pid = self()
    registry_name = :"BenchRegistry#{System.unique_integer()}"
    {:ok, _reg} = Registry.start_link(keys: :unique, name: registry_name)

    Benchee.run(%Benchee.Runner{
      title: "Process Discovery Performance",
      print: [configuration: false],
      formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
    }, %{
      "registry_lookup" => fn ->
        Registry.lookup(registry_name, test_pid)
      end,
      "process_whereis" => fn ->
        Process.whereis(:nonexistent_process)
      end,
      "supervisor_children_enum" => fn ->
        Supervisor.which_children(test_pid)
        rescue
          ArgumentError -> :ok
      end
    }, time: 3)

    Registry.unregister(registry_name, test_pid)
    :ok
  end

  def channel_benchmarks do
    IO.puts("\n=== Channel Operation Benchmarks ===")

    # Benchmark channel operations
    Benchee.run(%Benchee.Runner{
      title: "Channel Operations Performance",
      print: [configuration: false],
      formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
    }, %{
      "message_ref_generation" => fn ->
        Phoenix.SocketClient.Message.generate_ref()
      end,
      "join_message_creation" => fn ->
        Phoenix.SocketClient.Message.join("test:channel", %{user: "test"})
      end,
      "leave_message_creation" => fn ->
        Phoenix.SocketClient.Message.leave("test:channel")
      end,
      "push_message_creation" => fn ->
        Phoenix.SocketClient.Message.push("test:channel", "event", %{data: "test"})
      end
    }, time: 3)

    :ok
  end

  def memory_benchmarks do
    IO.puts("\n=== Memory Usage Benchmarks ===")

    # Test memory allocation patterns
    Benchee.run(%Benchee.Runner{
      title: "Memory Allocation Patterns",
      print: [configuration: false],
      formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
    }, %{
      "large_binary_creation" => fn ->
        :binary.copy(<<0>>, 1024 * 1024)  # 1MB binary
      end,
      "map_creation" => fn ->
        for i <- 1..1000, into: %{}, do: {"key_#{i}", "value_#{i}"}
      end,
      "list_concatenation" => fn ->
        Enum.reduce(1..1000, [], fn i, acc -> [i | acc] end)
      end
    }, memory_time: 5, time: 2)

    :ok
  end

  def concurrency_benchmarks do
    IO.puts("\n=== Concurrency Benchmarks ===")

    # Test concurrent message processing
    Benchee.run(%Benchee.Runner{
      title: "Concurrent Message Processing",
      print: [configuration: false],
      formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
    }, %{
      "sequential_tasks" => fn ->
        for i <- 1..10 do
          Task.async(fn ->
            :timer.sleep(1)
            i * 2
          end)
        end
        |> Enum.map(&Task.await/1)
      end,
      "parallel_tasks" => fn ->
        tasks = for i <- 1..10 do
          Task.async(fn ->
            :timer.sleep(1)
            i * 2
          end)
        end
        Task.await_many(tasks)
      end
    }, time: 5)

    :ok
  end

  @doc """
  Run a quick benchmark focusing on critical path operations.
  """
  def quick_benchmark do
    IO.puts("Running quick performance benchmark...")

    message = %Phoenix.SocketClient.Message{
      topic: "test:quick",
      event: "benchmark",
      payload: %{data: "quick_test"},
      ref: "quick"
    }

    Benchee.run(%{
      "message_encode" => fn ->
        Phoenix.SocketClient.Message.encode!(Phoenix.SocketClient.Message.V2, message, Jason)
      end,
      "message_decode" => fn ->
        encoded = Phoenix.SocketClient.Message.encode!(Phoenix.SocketClient.Message.V2, message, Jason)
        Phoenix.SocketClient.Message.decode!(Phoenix.SocketClient.Message.V2, encoded, Jason)
      end,
      "ref_generation" => fn ->
        Phoenix.SocketClient.Message.generate_ref()
      end
    }, time: 2)

    :ok
  end

  @doc """
  Profile memory usage with detailed statistics.
  """
  def memory_profile do
    IO.puts("Starting memory profile...")

    :erlang.garbage_collect()
    {initial_memory, _} = :erlang.process_info(self(), :memory)

    # Create many messages to test memory pressure
    messages = for i <- 1..1000 do
      %Phoenix.SocketClient.Message{
        topic: "test:#{i}",
        event: "memory_test",
        payload: %{id: i, data: String.duplicate("x", 100)},
        ref: "#{i}"
      }
    end

    # Encode all messages
    encoded = Enum.map(messages, fn msg ->
      Phoenix.SocketClient.Message.encode!(Phoenix.SocketClient.Message.V2, msg, Jason)
    end)

    :erlang.garbage_collect()
    {final_memory, _} = :erlang.process_info(self(), :memory)

    IO.puts("Initial memory: #{initial_memory} words")
    IO.puts("Final memory: #{final_memory} words")
    IO.puts("Memory increase: #{final_memory - initial_memory} words")
    IO.puts("Average per message: #{(final_memory - initial_memory) / 1000} words")

    :ok
  end
end