#!/usr/bin/env elixir

# Simple benchmark runner for development
# Usage: mix run bench/run_benchmarks.exs

Mix.install([{:benchee, "~> 1.3"}, {:benchee_html, "~> 1.0"}, {:jason, "~> 1.2"}])

# Load the application code
Code.append_path("_build/dev/lib/phoenix_socket_client/ebin")

# Import our benchmark module
Code.require_file("bench/socket_client_bench.exs")

case System.argv() do
  ["--quick"] ->
    IO.puts("Running quick benchmark...")
    Phoenix.SocketClient.Benchmarks.quick_benchmark()

  ["--memory"] ->
    IO.puts("Running memory profile...")
    Phoenix.SocketClient.Benchmarks.memory_profile()

  ["--help"] ->
    IO.puts("""
    Benchmark Runner Usage:
      mix run bench/run_benchmarks.exs           # Run all benchmarks
      mix run bench/run_benchmarks.exs --quick   # Run quick benchmark only
      mix run bench/run_benchmarks.exs --memory  # Run memory profile only
      mix run bench/run_benchmarks.exs --help    # Show this help
    """)

  _ ->
    IO.puts("Running full benchmark suite...")
    Phoenix.SocketClient.Benchmarks.run_all()
end