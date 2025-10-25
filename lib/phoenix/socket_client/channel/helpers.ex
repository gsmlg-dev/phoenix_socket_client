defmodule Phoenix.SocketClient.Channel.Helpers do
  @moduledoc """
  Helper functions for Phoenix.SocketClient.Channel GenServer callbacks.

  This module contains the actual implementation logic for channel callbacks,
  extracted from the `__using__` macro to improve code maintainability.
  """

  alias Phoenix.SocketClient.Channel.State
  alias Phoenix.SocketClient.{Message, Telemetry}

  @doc """
  Initializes a channel process.
  """
  def init_impl({sup_pid, socket_pid, topic, params, registry_name}) do
    Registry.register(registry_name, topic, self())

    {:ok,
     %State{
       sup_pid: sup_pid,
       socket_pid: socket_pid,
       topic: topic,
       params: params,
       registry_name: registry_name
     }}
  end

  @doc """
  Handles the :join call.
  """
  def handle_join_call(
        {_pid, _ref} = from,
        %{sup_pid: sup_pid, topic: topic, params: params} = state
      ) do
    message = Message.join(topic, params)

    push = Phoenix.SocketClient.push(sup_pid, message)

    {:noreply,
     %State{
       state
       | join_ref: push.ref,
         caller: elem(from, 0),
         pushes: [{from, push} | state.pushes],
         join_start_time: System.monotonic_time()
     }}
  end

  @doc """
  Handles the :leave call.
  """
  def handle_leave_call(
        _from,
        %{sup_pid: sup_pid, socket_pid: _socket_pid, topic: topic} = state
      ) do
    Phoenix.SocketClient.update_channel_status(sup_pid, self(), topic, :leaving)
    message = Message.leave(topic)
    _push = Phoenix.SocketClient.push(sup_pid, message)
    {:stop, :normal, :ok, %{state | leave_start_time: System.monotonic_time()}}
  end

  @doc """
  Handles the {:push, event, payload} call.
  """
  def handle_push_call(
        {event, payload},
        from,
        %{sup_pid: sup_pid, topic: topic} = state
      ) do
    message = %Message{
      topic: topic,
      event: event,
      payload: payload,
      ref: Message.generate_ref(),
      join_ref: state.join_ref
    }

    push = Phoenix.SocketClient.push(sup_pid, message)
    Telemetry.message_sent(self(), topic, event, payload)
    {:noreply, %State{state | pushes: [{from, push} | state.pushes]}}
  end

  @doc """
  Handles the :get_topic call.
  """
  def handle_get_topic_call(_from, state) do
    {:reply, state.topic, state}
  end

  @doc """
  Handles the {:push, event, payload} cast.
  """
  def handle_push_cast(
        {event, payload},
        %{sup_pid: sup_pid, topic: topic} = state
      ) do
    message = %Message{
      topic: topic,
      event: event,
      payload: payload,
      channel_pid: self(),
      join_ref: state.join_ref
    }

    Phoenix.SocketClient.push(sup_pid, message)
    Telemetry.message_sent(self(), topic, event, payload)
    {:noreply, state}
  end

  @doc """
  Handles phx_reply messages.
  """
  def handle_phx_reply_info(
        %Message{event: "phx_reply", ref: ref} = msg,
        %{pushes: pushes, topic: topic, join_ref: join_ref, params: params} = s,
        _handle_message_fun
      ) do
    pushes =
      case Enum.split_with(pushes, &(elem(&1, 1).ref == ref)) do
        {[{from_ref, _push}], pushes} ->
          %{"status" => status, "response" => response} = msg.payload

          case status do
            "ok" ->
              if ref == join_ref do
                if s.join_start_time do
                  duration = System.monotonic_time() - s.join_start_time
                  Telemetry.channel_join_duration(s.socket_pid, s.topic, duration)
                end

                Phoenix.SocketClient.update_channel_status(
                  s.sup_pid,
                  self(),
                  s.topic,
                  :joined,
                  params
                )

                Telemetry.channel_joined(s.sup_pid, s.topic, self(), msg.payload, %{})
              end

              Telemetry.message_received(self(), topic, "phx_reply", msg.payload)

            "error" ->
              if ref == join_ref do
                Phoenix.SocketClient.update_channel_status(
                  s.sup_pid,
                  self(),
                  s.topic,
                  :errored,
                  params
                )

                Telemetry.channel_join_error(s.sup_pid, s.topic, msg.payload, %{})
              end

              Telemetry.message_received(self(), topic, "phx_reply", msg.payload)

            _ ->
              :noop
          end

          GenServer.reply(from_ref, {String.to_atom(status), response})
          pushes

        {[], pushes} ->
          send(s.caller, %{msg | channel_pid: s.caller, topic: s.topic})
          pushes
      end

    {:noreply, %State{s | pushes: pushes}}
  end

  @doc """
  Handles regular message info.
  """
  def handle_message_info(%Message{} = message, state, handle_message_fun) do
    Telemetry.message_received(self(), state.topic, message.event, message.payload)
    handle_message_fun.(message.event, message.payload, state)
  end

  @doc """
  Handles channel termination.
  """
  def terminate_impl(
        reason,
        %{
          sup_pid: sup_pid,
          socket_pid: socket_pid,
          topic: topic,
          params: params,
          registry_name: registry_name,
          leave_start_time: start_time
        } = _state
      ) do
    if start_time do
      duration = System.monotonic_time() - start_time
      Telemetry.channel_leave_duration(socket_pid, topic, duration)
    end

    Registry.unregister(registry_name, topic)

    if sup_pid && topic do
      joined_channels = Phoenix.SocketClient.get_state(sup_pid, :joined_channels)
      channel_data = Map.get(joined_channels, topic)

      if reason == :normal and (channel_data && channel_data.status != :errored) do
        Phoenix.SocketClient.remove_channel(sup_pid, topic)
      else
        Phoenix.SocketClient.update_channel_status(sup_pid, self(), topic, :errored, params)
      end

      Telemetry.channel_left(self(), topic, reason)
    end

    :ok
  end
end
