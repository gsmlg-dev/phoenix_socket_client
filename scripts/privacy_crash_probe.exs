# Run with: MIX_ENV=test mix run scripts/privacy_crash_probe.exs
# Required confidentiality acceptance for issue #108; expected to FAIL on OTP 28.
# Keep this outside the partial-hardening regression suite while #108 is blocked.
# gen_server appends the original exception stacktrace after format_status/1,
# so FunctionClauseError arguments can expose payloads despite redacted state.
# This probe must pass before claiming arbitrary callback crashes are private.
ExUnit.start(autorun: false)

defmodule Phoenix.SocketClient.PrivacyCrashProbe do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Phoenix.SocketClient.{Message, MessageProcessor}

  @sentinel "SSH_PRIVATE_MATERIAL_SENTINEL"

  test "OTP processor termination reports redact queued data and payload-bearing current message" do
    {:ok, processor} = MessageProcessor.start_link(serializer: Message.V2)
    Process.unlink(processor)

    log =
      capture_log(fn ->
        catch_exit(GenServer.call(processor, {:unexpected_private_call, @sentinel}))
      end)

    assert log =~ "terminating"
    refute log =~ @sentinel
  end
end

result = ExUnit.run()

if result.failures > 0 do
  IO.puts("BLOCKED: issue #108 arbitrary-crash confidentiality is not satisfied")
  System.halt(1)
end
