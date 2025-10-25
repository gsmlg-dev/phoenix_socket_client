defmodule Phoenix.SocketClient.Message.V2 do
  @moduledoc """
  Phoenix Channels protocol V2 message encoder/decoder.

  Handles encoding and decoding of messages in the V2 protocol format (version "2.0.0").
  V2 protocol uses a 5-element array format: [join_ref, ref, topic, event, payload].
  """

  alias Phoenix.SocketClient.Message

  def decode!([join_ref, ref, topic, event, payload | _]) do
    %Message{
      join_ref: join_ref,
      ref: ref,
      topic: topic,
      event: event,
      payload: payload
    }
  end

  def encode!(%Message{} = msg) do
    [msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload]
  end
end
