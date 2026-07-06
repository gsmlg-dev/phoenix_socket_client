Logger.configure(level: :warning)

ExUnit.start(timeout: 120_000)

port = PhoenixSocketClientE2E.SocketServer.start()
Application.put_env(:phoenix_socket_client_e2e, :port, port)
