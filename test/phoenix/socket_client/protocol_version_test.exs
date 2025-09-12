defmodule Phoenix.SocketClient.ProtocolVersionTest do
  use ExUnit.Case, async: true

  alias Phoenix.SocketClient.Message

  describe "Message serialization" do
    test "V1 protocol serialization" do
      message = Message.join("rooms:test", %{user_id: 123})
      encoded = Message.encode!(Message.V1, message, Jason)

      assert is_binary(encoded)

      # Decode back and verify
      decoded = Message.decode!(Message.V1, encoded, Jason)
      assert decoded.topic == "rooms:test"
      assert decoded.event == "phx_join"
      assert decoded.payload == %{"user_id" => 123}
    end

    test "V2 protocol serialization" do
      message = Message.push("rooms:test", "new_msg", %{body: "Hello"})
      encoded = Message.encode!(Message.V2, message, Jason)

      assert is_binary(encoded)

      # Decode back and verify
      decoded = Message.decode!(Message.V2, encoded, Jason)
      assert decoded.topic == "rooms:test"
      assert decoded.event == "new_msg"
      assert decoded.payload == %{"body" => "Hello"}
    end

    test "message types creation" do
      # Join message
      join_msg = Message.join("rooms:lobby", %{token: "abc123"})
      assert join_msg.topic == "rooms:lobby"
      assert join_msg.event == "phx_join"
      assert join_msg.payload == %{token: "abc123"}
      assert is_binary(join_msg.ref)
      assert join_msg.ref == join_msg.join_ref

      # Leave message
      leave_msg = Message.leave("rooms:lobby")
      assert leave_msg.topic == "rooms:lobby"
      assert leave_msg.event == "phx_leave"
      assert leave_msg.payload == %{}
      assert is_binary(leave_msg.ref)
      assert leave_msg.join_ref == nil

      # Push message
      push_msg = Message.push("rooms:lobby", "new_msg", %{text: "Hello"})
      assert push_msg.topic == "rooms:lobby"
      assert push_msg.event == "new_msg"
      assert push_msg.payload == %{text: "Hello"}
      assert is_binary(push_msg.ref)
    end
  end
end
