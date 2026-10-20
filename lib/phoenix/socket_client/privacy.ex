defmodule Phoenix.SocketClient.Privacy do
  @moduledoc false

  require Logger

  defmacro __using__(_opts) do
    quote do
      @before_compile Phoenix.SocketClient.Privacy
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      defoverridable init: 1, terminate: 2

      @impl true
      def init(args) do
        Phoenix.SocketClient.Privacy.init(fn -> super(args) end)
      end

      @impl true
      def terminate(reason, state) do
        Phoenix.SocketClient.Privacy.terminate(reason, fn -> super(reason, state) end)
      end
    end
  end

  def init(callback) do
    try do
      case callback.() do
        {:ok, _state} = result ->
          result

        {:ok, _state, action} = result ->
          if init_action?(action), do: result, else: private_failure()

        :ignore ->
          :ignore

        {:stop, reason} when reason in [:normal, :shutdown] ->
          {:stop, reason}

        {:stop, {:already_registered, pid}} when is_pid(pid) ->
          exit_signal({:already_registered, pid})

        _private_failure ->
          private_failure()
      end
    catch
      _kind, _private_reason -> private_failure()
    end
  end

  def run(callback) do
    try do
      callback.()
    catch
      _kind, _private_reason -> private_failure()
    end
  end

  defp init_action?({:continue, _}), do: true
  defp init_action?(action) when action in [:hibernate, :infinity], do: true
  defp init_action?(action) when is_integer(action) and action >= 0, do: true

  defp init_action?({kind, time, _message}) when kind in [:timeout, :hibernate],
    do: time == :infinity or (is_integer(time) and time >= 0)

  defp init_action?({kind, time, _message, opts}) when kind in [:timeout, :hibernate] do
    opts = if is_list(opts), do: opts, else: [opts]

    absolute =
      Enum.reduce_while(opts, false, fn
        {:abs, value}, _ when is_boolean(value) -> {:cont, value}
        _, _ -> {:halt, :invalid}
      end)

    absolute != :invalid and
      (time == :infinity or (is_integer(time) and (absolute or time >= 0)))
  end

  defp init_action?(_), do: false

  # OTP reports original exception arguments and queued messages independently
  # of format_status/1. A self-directed exit signal bypasses those reports while
  # retaining an abnormal reason so transient children still restart.
  def terminate(reason, cleanup) do
    try do
      cleanup.()
    catch
      _kind, _private_reason -> private_failure()
    end

    case reason do
      :normal -> :ok
      :shutdown -> :ok
      {:shutdown, _private_reason} -> exit_signal(:shutdown)
      _private_reason -> private_failure()
    end
  end

  defp private_failure do
    Logger.error("Phoenix.SocketClient process terminating: private callback failure")
    exit_signal(:private_callback_failure)
  end

  defp exit_signal(reason) do
    Process.flag(:trap_exit, false)
    Process.exit(self(), reason)
  end

  @text_fields [:topic, :event, :ref, :join_ref, :host]
  @atom_fields [
    :event,
    :transport,
    :status,
    :old_status,
    :new_status,
    :component,
    :operation,
    :action,
    :kind,
    :cache_type,
    :process_name,
    :serializer,
    :json_library,
    :registry_name
  ]
  @number_fields [
    :duration,
    :timestamp,
    :size_bytes,
    :message_size,
    :pattern_size,
    :memory_saved,
    :attempt,
    :count,
    :batch_size,
    :batch_interval,
    :max_queue_size,
    :pool_size,
    :total_count,
    :total_memory,
    :to_send_count,
    :max_pending_messages,
    :pending_decodes_count,
    :pending_replies_count,
    :encode_queue_size,
    :decode_queue_size,
    :joined_channels_count,
    :pushes_count,
    :patterns_count
  ]
  @boolean_fields [
    :sync_mode,
    :connected?,
    :closing?,
    :hibernation_enabled,
    :reconnect,
    :reconnecting
  ]
  @pid_fields [:pid, :socket_pid, :channel_pid, :sup_pid, :sender, :message_processor]

  # Metadata is a public observability boundary. Unknown fields never cross it,
  # even when their names do not look sensitive.
  def metadata(metadata) when is_map(metadata) do
    Enum.reduce(Map.to_list(metadata), %{}, fn
      {:url, url}, safe when is_binary(url) ->
        case safe_url(url) do
          nil -> safe
          url -> Map.put(safe, :url, url)
        end

      {key, value}, safe when key in @text_fields and is_binary(value) ->
        Map.put(safe, key, value)

      {key, value}, safe when key in @atom_fields and is_atom(value) ->
        Map.put(safe, key, value)

      {key, value}, safe when key in @number_fields and is_number(value) ->
        Map.put(safe, key, value)

      {key, value}, safe when key in @boolean_fields and is_boolean(value) ->
        Map.put(safe, key, value)

      {key, value}, safe when key in @pid_fields and is_pid(value) ->
        Map.put(safe, key, value)

      {:socket_ref, value}, safe when is_reference(value) ->
        Map.put(safe, :socket_ref, value)

      {key, value}, safe when key in [:reason, :error] ->
        Map.put(safe, key, reason(value))

      _, safe ->
        safe
    end)
  end

  defp safe_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["ws", "wss", "http", "https"] and is_binary(host) ->
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp reason(value) when is_atom(value), do: value
  defp reason({value, _}) when is_atom(value), do: value
  defp reason(_), do: :redacted

  # Termination handling also replaces the original exception stacktrace, which
  # OTP appends outside this callback.
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, state_summary(state)}
      {:reason, value} -> {:reason, reason(value)}
      {:log, _} -> {:log, []}
      {key, _} -> {key, :redacted}
    end)
  end

  defp state_summary(state) when is_map(state) do
    state
    |> Map.drop(@text_fields ++ [:url, :reason, :error])
    |> metadata()
    |> add_count(:pending_decodes_count, Map.get(state, :pending_decodes))
    |> add_count(:pending_replies_count, Map.get(state, :pending_replies))
    |> add_count(:joined_channels_count, Map.get(state, :joined_channels))
    |> add_count(:patterns_count, Map.get(state, :patterns))
    |> add_count(:pushes_count, Map.get(state, :pushes))
  end

  defp state_summary(_), do: :redacted

  defp add_count(summary, key, value) when is_map(value),
    do: Map.put(summary, key, map_size(value))

  defp add_count(summary, key, value) when is_list(value),
    do: Map.put(summary, key, length(value))

  defp add_count(summary, _, _), do: summary
end
