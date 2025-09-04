defmodule PhoenixSocketClient.Message.V1 do
  @moduledoc """
  DEPRECATED: V1 protocol serializer for legacy Phoenix Channels support.

  This module provides compatibility with Phoenix Channels protocol v1.0.0.
  It is deprecated and will be removed in a future version. Use V2 protocol instead.
  """

  alias PhoenixSocketClient.Message

  @doc false
  def decode!(msg) do
    IO.warn("PhoenixSocketClient.Message.V1 is deprecated. Use Message.V2 instead.")

    %Message{
      ref: msg["ref"],
      topic: msg["topic"],
      event: msg["event"],
      payload: msg["payload"]
    }
  end

  @doc false
  def encode!(%Message{} = msg) do
    IO.warn("PhoenixSocketClient.Message.V1 is deprecated. Use Message.V2 instead.")

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
