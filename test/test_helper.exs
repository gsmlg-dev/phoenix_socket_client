Application.put_env(:ex_unit, :assert_receive_timeout, 800)
ExUnit.start(timeout: 120_000)

Logger.configure(level: :debug)

# Start the mock Phoenix server with dynamic port
port = PhoenixSocketClientTest.MockServer.start()
IO.puts("Mock server started on port: #{port}")
