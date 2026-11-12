defmodule Phoenix.SocketClient.SupervisorShutdownTest do
  use ExUnit.Case, async: false

  setup_all do
    Application.ensure_all_started(:gaoxy_http)
    Application.ensure_all_started(:phoenix)
    :ok
  end

  defp socket_config(name) do
    port = Application.get_env(:phoenix_socket_client_test, :port, 5807)

    [
      name: name,
      url: "ws://127.0.0.1:#{port}/ws/admin/websocket",
      reconnect: false,
      auto_connect: true,
      vsn: "2.0.0"
    ]
  end

  test "process lookups do not call the supervisor" do
    name = :"shutdown_lookup_#{System.unique_integer([:positive])}"
    {:ok, sup} = Phoenix.SocketClient.Supervisor.start_link(socket_config(name))

    # A suspended supervisor cannot answer `which_children`, just like one
    # that is busy executing `Supervisor.stop/3`.
    :sys.suspend(sup)

    lookups =
      Task.async(fn ->
        Enum.map(
          [:socket_state, :socket, :channel_manager],
          &Phoenix.SocketClient.get_process_pid(sup, &1)
        )
      end)

    result = Task.yield(lookups, 500) || Task.shutdown(lookups, :brutal_kill)
    :sys.resume(sup)

    assert {:ok, pids} = result
    assert Enum.all?(pids, &is_pid/1)

    Supervisor.stop(sup)
  end
end
