defmodule Phoenix.SocketClient.Privacy do
  @moduledoc false

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

  # format_status/1 also receives the current message, debug events and reason
  # on termination. OTP adds stacktraces outside this callback; these summaries
  # do not provide a guarantee that arbitrary callback crashes are private.
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
