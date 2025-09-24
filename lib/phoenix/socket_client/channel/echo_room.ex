defmodule Phoenix.SocketClient.Channel.EchoRoom do
  @moduledoc """
  A basic channel implementation that forwards all messages to the caller and prints them.
  """
  use Phoenix.SocketClient.Channel

  @impl true
  def handle_message(event, payload, state) do
    IO.puts("Received message: event=#{event}, payload=#{inspect(payload)}")
    send(state.caller, payload)
    {:noreply, state}
  end
end
