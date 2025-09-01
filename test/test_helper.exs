Application.put_env(:ex_unit, :assert_receive_timeout, 800)
ExUnit.start()

Logger.configure(level: :debug)

# Start the mock Phoenix server
PhoenixSocketClientTest.MockServer.start()
