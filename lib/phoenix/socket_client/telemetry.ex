defmodule Phoenix.SocketClient.Telemetry do
  @moduledoc """
  Telemetry integration for Phoenix.SocketClient.

  This module provides telemetry events for monitoring socket connections,
  channel joins/leaves, message handling, and connection lifecycle events.
  """

  @doc """
  Emits a telemetry event with the given name and measurements/metadata.
  """
  @spec emit_event(list(atom() | String.t()), map(), map()) :: :ok
  def emit_event(event_name, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(event_name, measurements, metadata)
  end

  @doc """
  Emits socket connection event.
  """
  @spec socket_connected(pid(), String.t(), map()) :: :ok
  def socket_connected(pid, url, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :socket_connected], %{}, %{
      pid: pid,
      url: url,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits socket disconnection event.
  """
  @spec socket_disconnected(pid(), String.t(), atom(), map()) :: :ok
  def socket_disconnected(pid, url, reason, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :socket_disconnected], %{}, %{
      pid: pid,
      url: url,
      reason: reason,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits socket connection attempt event.
  """
  @spec socket_connecting(pid(), String.t(), map()) :: :ok
  def socket_connecting(pid, url, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :socket_connecting], %{}, %{
      pid: pid,
      url: url,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits socket connection error event.
  """
  @spec socket_connection_error(pid(), String.t(), any(), map()) :: :ok
  def socket_connection_error(pid, url, error, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :socket_connection_error], %{}, %{
      pid: pid,
      url: url,
      error: error,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits channel join event.
  """
  @spec channel_joined(pid(), String.t(), String.t(), map(), map()) :: :ok
  def channel_joined(pid, topic, channel_pid, response, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :channel_joined], %{}, %{
      pid: pid,
      topic: topic,
      channel_pid: channel_pid,
      response: response,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits channel join error event.
  """
  @spec channel_join_error(pid(), String.t(), any(), map()) :: :ok
  def channel_join_error(pid, topic, error, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :channel_join_error], %{}, %{
      pid: pid,
      topic: topic,
      error: error,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits channel leave event.
  """
  @spec channel_left(pid(), String.t(), String.t(), map()) :: :ok
  def channel_left(pid, topic, reason, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :channel_left], %{}, %{
      pid: pid,
      topic: topic,
      reason: reason,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits message sent event.
  """
  @spec message_sent(pid(), String.t(), String.t(), map(), map()) :: :ok
  def message_sent(pid, topic, event, payload, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :message_sent], %{}, %{
      pid: pid,
      topic: topic,
      event: event,
      payload: payload,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits message received event.
  """
  @spec message_received(pid(), String.t(), String.t(), map(), map()) :: :ok
  def message_received(pid, topic, event, payload, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :message_received], %{}, %{
      pid: pid,
      topic: topic,
      event: event,
      payload: payload,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits heartbeat event.
  """
  @spec heartbeat_sent(pid(), String.t(), map()) :: :ok
  def heartbeat_sent(pid, url, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :socket_heartbeat], %{}, %{
      pid: pid,
      url: url,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits reconnection attempt event.
  """
  @spec reconnecting(pid(), String.t(), integer(), map()) :: :ok
  def reconnecting(pid, url, attempt, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :socket_reconnecting], %{}, %{
      pid: pid,
      url: url,
      attempt: attempt,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits socket status change event.
  """
  @spec socket_status_changed(pid(), String.t(), atom(), atom(), map()) :: :ok
  def socket_status_changed(pid, url, old_status, new_status, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :socket_status_changed], %{}, %{
      pid: pid,
      url: url,
      old_status: old_status,
      new_status: new_status,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Emits channel status change event.
  """
  @spec channel_status_changed(pid(), String.t(), pid(), atom(), atom(), map()) :: :ok
  def channel_status_changed(pid, topic, channel_pid, old_status, new_status, _metadata \\ %{}) do
    emit_event([:phoenix_socket_client, :channel_status_changed], %{}, %{
      pid: pid,
      topic: topic,
      channel_pid: channel_pid,
      old_status: old_status,
      new_status: new_status,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc """
  Attaches a telemetry handler for debugging purposes.

  ## Example

      Phoenix.SocketClient.Telemetry.attach_debug_handler()
  """
  @spec attach_debug_handler() :: :ok
  def attach_debug_handler do
    :telemetry.attach_many(
      "phoenix-socket-client-debug",
      [
        [:phoenix_socket_client, :socket_connected],
        [:phoenix_socket_client, :socket_disconnected],
        [:phoenix_socket_client, :socket_connecting],
        [:phoenix_socket_client, :socket_connection_error],
        [:phoenix_socket_client, :socket_status_changed],
        [:phoenix_socket_client, :channel_joined],
        [:phoenix_socket_client, :channel_join_error],
        [:phoenix_socket_client, :channel_left],
        [:phoenix_socket_client, :channel_status_changed],
        [:phoenix_socket_client, :message_sent],
        [:phoenix_socket_client, :message_received],
        [:phoenix_socket_client, :socket_heartbeat],
        [:phoenix_socket_client, :socket_reconnecting]
      ],
      &debug_handler/4,
      %{}
    )
  end

  @doc """
  Detaches the debug handler.
  """
  @spec detach_debug_handler() :: :ok
  def detach_debug_handler do
    :telemetry.detach("phoenix-socket-client-debug")
  end

  defp debug_handler(event_name, measurements, metadata, _config) do
    IO.inspect({event_name, measurements, metadata}, label: "[Phoenix.SocketClient] Telemetry")
  end
end
