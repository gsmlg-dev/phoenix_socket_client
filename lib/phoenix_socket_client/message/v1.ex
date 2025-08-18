defmodule PhoenixSocketClient.Message.V1 do
  alias PhoenixSocketClient.Message

  def decode!(msg) do
    %Message{
      ref: msg["ref"],
      topic: msg["topic"],
      event: msg["event"],
      payload: msg["payload"]
    }
  end

  def encode!(%Message{} = msg) do
    result =
      msg
      |> Map.take([:topic, :event, :payload, :ref])

    # Add join_ref if it's a join message
    if msg.event == "phx_join" do
      Map.put(result, :join_ref, msg.ref)
    else
      result
    end
  end
end
