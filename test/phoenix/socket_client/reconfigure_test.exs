defmodule Phoenix.SocketClient.ReconfigureTest do
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
      registry_name: registry_name,
      custom_config: "foo"
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

  describe "reconfigure/2" do
    test "updates non-connection-related config without restarting the socket" do
      name = :"reconfigure_no_restart_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      wait_for_socket(name)

      socket_pid_before = Phoenix.SocketClient.get_process_pid(sup_pid, :socket)
      assert is_pid(socket_pid_before)

      assert :ok = Phoenix.SocketClient.reconfigure(sup_pid, custom_config: "bar")

      assert "bar" == Phoenix.SocketClient.get_state(sup_pid, :custom_config)

      socket_pid_after = Phoenix.SocketClient.get_process_pid(sup_pid, :socket)
      assert socket_pid_before == socket_pid_after
    end

    test "restarts the socket when a connection-related config changes" do
      name = :"reconfigure_restart_#{System.unique_integer([:positive])}"
      config = get_socket_config() |> Keyword.put(:name, name)
      {:ok, sup_pid} = Phoenix.SocketClient.Supervisor.start_link(config)

      wait_for_socket(name)

      socket_pid_before = Phoenix.SocketClient.get_process_pid(sup_pid, :socket)
      assert is_pid(socket_pid_before)

      port = get_port()
      new_url = "ws://127.0.0.1:#{port}/ws/admin/websocket?new=true"
      assert :ok = Phoenix.SocketClient.reconfigure(sup_pid, url: new_url)

      # It takes some time for the socket to restart
      Process.sleep(500)

      socket_pid_after = Phoenix.SocketClient.get_process_pid(sup_pid, :socket)
      assert is_pid(socket_pid_after)
      assert socket_pid_before != socket_pid_after

      assert wait_for_socket(name)
    end
  end
end
