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

  # Generic Event Functions

  @doc """
  Emits a generic socket event.
  """
  def socket_event(action, pid, url, metadata \\ %{}) do
    base_metadata = %{
      pid: pid,
      url: url,
      timestamp: System.system_time(:millisecond)
    }

    emit_event(
      [:phoenix_socket_client, :socket],
      %{},
      Map.merge(base_metadata, Map.put(metadata, :action, action))
    )
  end

  @doc """
  Emits a generic channel event.
  """
  def channel_event(action, pid, topic, metadata \\ %{}) do
    base_metadata = %{
      pid: pid,
      topic: topic,
      timestamp: System.system_time(:millisecond)
    }

    emit_event(
      [:phoenix_socket_client, :channel],
      %{},
      Map.merge(base_metadata, Map.put(metadata, :action, action))
    )
  end

  @doc """
  Emits a generic message event.
  """
  def message_event(action, pid, topic, event, payload, metadata \\ %{}) do
    base_metadata = %{
      pid: pid,
      topic: topic,
      event: event,
      payload: payload,
      timestamp: System.system_time(:millisecond)
    }

    emit_event(
      [:phoenix_socket_client, :message],
      %{},
      Map.merge(base_metadata, Map.put(metadata, :action, action))
    )
  end

  @doc """
  Emits a generic state change event.
  """
  def state_change_event(type, id, old_status, new_status, metadata \\ %{}) do
    base_metadata = %{
      id: id,
      old_status: old_status,
      new_status: new_status,
      timestamp: System.system_time(:millisecond)
    }

    emit_event(
      [:phoenix_socket_client, :state_change],
      %{},
      Map.merge(base_metadata, Map.put(metadata, :type, type))
    )
  end

  # Specific Event Functions

  @doc """
  Emits socket connection event.
  """
  @spec socket_connected(pid(), String.t(), map()) :: :ok
  def socket_connected(pid, url, metadata \\ %{}) do
    socket_event(:connected, pid, url, metadata)
  end

  @doc """
  Emits socket disconnection event.
  """
  @spec socket_disconnected(pid(), String.t(), atom(), map()) :: :ok
  def socket_disconnected(pid, url, reason, metadata \\ %{}) do
    socket_event(:disconnected, pid, url, Map.put(metadata, :reason, reason))
  end

  @doc """
  Emits socket connection attempt event.
  """
  @spec socket_connecting(pid(), String.t(), map()) :: :ok
  def socket_connecting(pid, url, metadata \\ %{}) do
    socket_event(:connecting, pid, url, metadata)
  end

  @doc """
  Emits socket connection error event.
  """
  @spec socket_connection_error(pid(), String.t(), any(), map()) :: :ok
  def socket_connection_error(pid, url, error, metadata \\ %{}) do
    socket_event(:connection_error, pid, url, Map.put(metadata, :error, error))
  end

  @doc """
  Emits channel join event.
  """
  @spec channel_joined(pid(), String.t(), pid(), map(), map()) :: :ok
  def channel_joined(pid, topic, channel_pid, response, metadata \\ %{}) do
    channel_event(
      :joined,
      pid,
      topic,
      Map.merge(metadata, %{channel_pid: channel_pid, response: response})
    )
  end

  @doc """
  Emits channel join error event.
  """
  @spec channel_join_error(pid(), String.t(), any(), map()) :: :ok
  def channel_join_error(pid, topic, error, metadata \\ %{}) do
    channel_event(:join_error, pid, topic, Map.put(metadata, :error, error))
  end

  @doc """
  Emits channel leave event.
  """
  @spec channel_left(pid(), String.t(), atom(), map()) :: :ok
  def channel_left(pid, topic, reason, metadata \\ %{}) do
    channel_event(:left, pid, topic, Map.put(metadata, :reason, reason))
  end

  @doc """
  Emits message sent event.
  """
  @spec message_sent(pid(), String.t(), String.t(), map(), map()) :: :ok
  def message_sent(pid, topic, event, payload, metadata \\ %{}) do
    message_event(:sent, pid, topic, event, payload, metadata)
  end

  @doc """
  Emits message received event.
  """
  @spec message_received(pid(), String.t(), String.t(), map(), map()) :: :ok
  def message_received(pid, topic, event, payload, metadata \\ %{}) do
    message_event(:received, pid, topic, event, payload, metadata)
  end

  @doc """
  Emits heartbeat event.
  """
  @spec heartbeat_sent(pid(), String.t(), map()) :: :ok
  def heartbeat_sent(pid, url, metadata \\ %{}) do
    socket_event(:heartbeat, pid, url, metadata)
  end

  @doc """
  Emits reconnection attempt event.
  """
  @spec reconnecting(pid(), String.t(), integer(), map()) :: :ok
  def reconnecting(pid, url, attempt, metadata \\ %{}) do
    socket_event(:reconnecting, pid, url, Map.put(metadata, :attempt, attempt))
  end

  @doc """
  Emits socket status change event.
  """
  @spec socket_status_changed(pid(), String.t(), atom(), atom()) :: :ok
  def socket_status_changed(pid, url, old_status, new_status) do
    state_change_event(:socket, url, old_status, new_status, %{pid: pid})
  end

  @doc """
  Emits channel status change event.
  """
  @spec channel_status_changed(pid(), String.t(), atom(), atom()) :: :ok
  def channel_status_changed(pid, topic, old_status, new_status) do
    state_change_event(:channel, topic, old_status, new_status, %{pid: pid})
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
        [:phoenix_socket_client, :socket],
        [:phoenix_socket_client, :channel],
        [:phoenix_socket_client, :message],
        [:phoenix_socket_client, :state_change]
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
