defmodule PhoenixSocketClient.Socket.ChannelsTest do
  use ExUnit.Case, async: true

  alias PhoenixSocketClient.Socket
  alias PhoenixSocketClient.Socket.Channels

  setup do
    id = :"channel_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = Channels.start_link(id: id)
    %{channels: pid, id: id}
  end

  test "start_link/1 starts the supervisor", %{channels: pid} do
    assert Process.alive?(pid)
  end

  test "start_channel/4 starts a channel", %{channels: pid, id: id} do
    {:ok, socket_pid} = Socket.start_link([url: "ws://localhost:4000"], name: id)
    {:ok, channel} = Channels.start_channel(pid, socket_pid, "test:topic", %{})
    assert Process.alive?(channel)
    Supervisor.stop(socket_pid)
  end
end
