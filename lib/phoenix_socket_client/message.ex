defmodule PhoenixSocketClient.Message do
  @moduledoc """
  Defines the message structure and protocol for Phoenix Channels communication.

  This module provides message encoding/decoding and handles both V1 and V2
  Phoenix Channels protocol versions. It defines the structure for messages
  sent between client and server.

  ## Message Structure

  The message struct contains:
  - `:topic` - The channel topic (e.g., "rooms:lobby")
  - `:event` - The event name (e.g., "phx_join", "new_msg")
  - `:payload` - The message payload (any term)
  - `:channel_pid` - The channel process PID (internal use)
  - `:ref` - Message reference for reply matching
  - `:join_ref` - Reference for channel joins

  ## Protocol Versions

  Supports both V1 and V2 Phoenix Channels protocols:
  - V1: Legacy protocol with different message format
  - V2: Current protocol with improved message structure
  """

  @typedoc """
  Represents a Phoenix Channels message.
  """
  @type t :: %__MODULE__{
          topic: String.t() | nil,
          event: String.t() | nil,
          payload: any(),
          channel_pid: pid() | nil,
          ref: String.t() | nil,
          join_ref: String.t() | nil
        }

  defstruct topic: nil,
            event: nil,
            payload: nil,
            channel_pid: nil,
            ref: nil,
            join_ref: nil

  @doc """
  Returns the appropriate serializer module for the given protocol version.

  ## Parameters
    * `vsn` - Protocol version string ("1.0.0" or "2.0.0")

  ## Returns
    * Module - Serializer module for the protocol version

  ## Deprecation Notice
  V1 protocol ("1.0.0") is deprecated and will be removed in a future version.
  Use V2 protocol ("2.0.0") for new applications.
  """
  @spec serializer(String.t()) :: module()
  def serializer("1.0.0") do
    IO.warn("Phoenix Channels V1 protocol is deprecated. Use V2 (2.0.0) instead.")
    __MODULE__.V1
  end

  def serializer("2.0.0"), do: __MODULE__.V2
  def serializer(_), do: __MODULE__.V2

  @doc """
  Decodes a raw message string into a Message struct.

  ## Parameters
    * `serializer` - Serializer module (V1 or V2)
    * `msg` - Raw JSON message string
    * `json_library` - JSON library module (e.g., Jason)

  ## Returns
    * `PhoenixSocketClient.Message.t()` - Decoded message struct

  ## Examples
      message = PhoenixSocketClient.Message.decode!(V2, raw_json, Jason)
  """
  @spec decode!(module(), String.t(), module()) :: t()
  def decode!(serializer, msg, json_library) do
    json_library.decode!(msg)
    |> serializer.decode!()
  end

  @doc """
  Encodes a Message struct into a JSON string.

  ## Parameters
    * `serializer` - Serializer module (V1 or V2)
    * `msg` - Message struct to encode
    * `json_library` - JSON library module (e.g., Jason)

  ## Returns
    * String - JSON-encoded message

  ## Examples
      json = PhoenixSocketClient.Message.encode!(V2, message, Jason)
  """
  @spec encode!(module(), t(), module()) :: String.t()
  def encode!(serializer, %__MODULE__{} = msg, json_library) do
    serializer.encode!(msg)
    |> json_library.encode!()
  end

  @doc """
  Creates a join message for channel subscription.

  ## Parameters
    * `topic` - Channel topic (e.g., "rooms:lobby")
    * `params` - Join parameters (map or keyword list)

  ## Returns
    * `PhoenixSocketClient.Message.t()` - Join message

  ## Examples
      message = PhoenixSocketClient.Message.join("rooms:lobby", %{user_id: 123})
  """
  @spec join(String.t(), map() | keyword()) :: t()
  def join(topic, params) do
    ref = generate_ref()

    %__MODULE__{
      topic: topic,
      event: "phx_join",
      payload: params,
      ref: ref,
      join_ref: ref
    }
  end

  @doc """
  Creates a leave message for channel unsubscription.

  ## Parameters
    * `topic` - Channel topic to leave

  ## Returns
    * `PhoenixSocketClient.Message.t()` - Leave message

  ## Examples
      message = PhoenixSocketClient.Message.leave("rooms:lobby")
  """
  @spec leave(String.t()) :: t()
  def leave(topic) do
    %__MODULE__{
      topic: topic,
      event: "phx_leave",
      payload: %{},
      ref: generate_ref(),
      join_ref: nil
    }
  end

  @doc """
  Creates a push message for sending data to a channel.

  ## Parameters
    * `topic` - Channel topic
    * `event` - Event name (e.g., "new_msg")
    * `payload` - Message payload

  ## Returns
    * `PhoenixSocketClient.Message.t()` - Push message

  ## Examples
      message = PhoenixSocketClient.Message.push("rooms:lobby", "new_msg", %{body: "Hello"})
  """
  @spec push(String.t(), String.t(), any()) :: t()
  def push(topic, event, payload) do
    ref = generate_ref()

    %__MODULE__{
      topic: topic,
      event: event,
      payload: payload,
      ref: ref
    }
  end

  @doc """
  Generates a unique reference string for message correlation.

  ## Returns
    * String - Unique reference string
  """
  @spec generate_ref() :: String.t()
  def generate_ref do
    Integer.to_string(System.unique_integer([:positive]))
  end
end
