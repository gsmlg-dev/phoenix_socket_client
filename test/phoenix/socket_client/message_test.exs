defmodule Phoenix.SocketClient.MessageTest do
  use ExUnit.Case, async: false

  alias Phoenix.SocketClient.Message

  describe "v1 serializer deprecated" do
    test "V1 serializer no longer available" do
      # V1 protocol has been deprecated and removed
      # All versions now default to V2
      assert Message.serializer("1.0.0") == Message.V2
    end
  end

  describe "v2 serializer" do
    test "encode" do
      msg = %{
        join_ref: "1",
        ref: "1",
        topic: "1234",
        event: "new:thing",
        payload: %{"a" => "b"}
      }

      v2_msg = Message.V2.encode!(struct(Message, msg))
      assert ["1", "1", "1234", "new:thing", %{"a" => "b"}] == v2_msg
    end

    test "decode" do
      msg = %{
        join_ref: "1",
        ref: "1",
        topic: "1234",
        event: "new:thing",
        payload: %{"a" => "b"}
      }

      v2_msg = Message.V2.decode!(["1", "1", "1234", "new:thing", %{"a" => "b"}])
      assert struct(Message, msg) == v2_msg
    end
  end

  def to_struct(kind, attrs) do
    struct = struct(kind)

    Enum.reduce(Map.to_list(struct), struct, fn {k, _}, acc ->
      case Map.fetch(attrs, Atom.to_string(k)) do
        {:ok, v} -> %{acc | k => v}
        :error -> acc
      end
    end)
  end
end
