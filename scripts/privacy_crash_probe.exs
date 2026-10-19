# Run with: MIX_ENV=test mix run scripts/privacy_crash_probe.exs
# Required confidentiality acceptance for issue #108, including OTP 28's original
# exception stacktrace appended outside format_status/1. The process must really
# terminate and produce a report without exposing FunctionClauseError arguments.
ExUnit.start(autorun: false)

defmodule Phoenix.SocketClient.PrivacyCrashProbe do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Phoenix.SocketClient.{Message, MessageProcessor}

  @sentinel "SSH_PRIVATE_MATERIAL_SENTINEL"

  test "OTP processor termination reports redact queued data and payload-bearing current message" do
    {:ok, processor} = MessageProcessor.start_link(serializer: Message.V2)
    Process.unlink(processor)
    ref = Process.monitor(processor)

    log =
      capture_log(fn ->
        catch_exit(GenServer.call(processor, {:unexpected_private_call, @sentinel}))
        assert_receive {:DOWN, ^ref, :process, ^processor, :private_callback_failure}
      end)

    assert log =~ "terminating"
    refute log =~ @sentinel
  end
end

result = ExUnit.run()

if result.failures > 0 do
  IO.puts("FAIL: issue #108 crash confidentiality is not satisfied")
  System.halt(1)
end
