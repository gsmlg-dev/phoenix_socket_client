defmodule Phoenix.SocketClient.Channel.Room do
  @moduledoc """
  A basic channel implementation that forwards all messages to the caller.
  """
  use Phoenix.SocketClient.Channel

  @impl true
  def handle_message(_event, payload, state) do
    send(state.caller, payload)
    {:noreply, state}
  end
end
