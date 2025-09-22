defmodule Phoenix.SocketClient.Channel.Room do
  use Phoenix.SocketClient.Channel

  @impl true
  def handle_message(_event, payload, state) do
    send(state.caller, payload)
    {:noreply, state}
  end
end
