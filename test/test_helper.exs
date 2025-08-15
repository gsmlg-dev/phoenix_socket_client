Application.put_env(:ex_unit, :assert_receive_timeout, 800)
ExUnit.start()

Logger.configure(level: :error)

# Starts web server applications
Application.ensure_all_started(:bandit)
Application.ensure_all_started(:phoenix)
