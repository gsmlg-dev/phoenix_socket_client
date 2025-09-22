defmodule Phoenix.SocketClient.Channel do
  @callback handle_message(event :: String.t(), payload :: map(), state :: map()) ::
              {:noreply, new_state :: map()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Phoenix.SocketClient.Channel
      use GenServer
      alias Phoenix.SocketClient.Channel.State
      alias Phoenix.SocketClient.{Message, Telemetry}

      @doc false
      def start_link(args) do
        GenServer.start_link(__MODULE__, args)
      end

      # Callbacks
      @impl true
      def init({sup_pid, socket_pid, topic, params, registry_name}) do
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

      @impl true
      def handle_call(
            :join,
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

      @impl true
      def handle_call(
            :leave,
            _from,
            %{sup_pid: sup_pid, socket_pid: _socket_pid, topic: topic} = state
          ) do
        Phoenix.SocketClient.update_channel_status(sup_pid, self(), topic, :leaving)
        message = Message.leave(topic)
        _push = Phoenix.SocketClient.push(sup_pid, message)
        {:stop, :normal, :ok, %{state | leave_start_time: System.monotonic_time()}}
      end

      @impl true
      def handle_call({:push, event, payload}, from, %{sup_pid: sup_pid, topic: topic} = state) do
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

      @impl true
      def handle_cast({:push, event, payload}, %{sup_pid: sup_pid, topic: topic} = state) do
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

      @impl true
      def handle_info(
            %Message{event: "phx_reply", ref: ref} = msg,
            %{pushes: pushes, topic: topic, join_ref: join_ref, params: params} = s
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

      @impl true
      def handle_info(%Message{} = message, state) do
        Telemetry.message_received(self(), state.topic, message.event, message.payload)
        handle_message(message.event, message.payload, state)
      end

      @impl true
      def terminate(
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

      defoverridable init: 1,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     terminate: 2
    end
  end

  @timeout 5_000

  @doc false
  def stop(pid) do
    leave(pid)
  end

  @doc """
  Join a channel topic through a socket with optional params

  A socket can only join a topic once. If the socket you pass already has a
  channel connection for the supplied topic, you will receive an error
  `{:error, {:already_joined, pid}}` with the channel pid of the process joined
  to that topic through that socket. If you require to join the same topic with
  multiple processes, you will need to start a new socket process for each channel.

  Calling join will link the caller to the channel process.
  """
  @spec join(pid | atom, binary, map, non_neg_integer) ::
          {:ok, map, pid}
          | {:error, :socket_not_connected}
          | {:error, :timeout}
          | {:error, any}
  def join(sup_pid, topic, params \\ %{}, timeout \\ @timeout)
  def join(nil, _topic, _params, _timeout), do: {:error, :socket_not_started}

  def join(sup_pid, topic, params, timeout) do
    if Phoenix.SocketClient.connected?(sup_pid) do
      case Phoenix.SocketClient.channel_join(sup_pid, topic, params) do
        {:ok, pid} -> do_join(pid, sup_pid, topic, params, timeout)
        {:error, {:already_started, _}} = error -> error
        error -> error
      end
    else
      {:error, :socket_not_connected}
    end
  end

  @doc """
  Leave the channel topic and stop the channel
  """
  @spec leave(pid) :: :ok
  def leave(pid) do
    GenServer.call(pid, :leave)
  end

  @doc """
  Push a message to the server and wait for a response or timeout

  The server must be configured to return `{:reply, _, socket}`
  otherwise, the call will timeout.
  """
  @spec push(pid, binary, map, non_neg_integer) ::
          {:ok, map()} | {:error, map() | :timeout}
  def push(pid, event, payload, timeout \\ @timeout) do
    GenServer.call(pid, {:push, event, payload}, timeout)
  end

  @doc """
  Push a message to the server and do not wait for a response
  """
  @spec push_async(pid, binary, map) :: :ok
  def push_async(pid, event, payload) do
    GenServer.cast(pid, {:push, event, payload})
  end

  defp do_join(pid, sup_pid, topic, params, timeout) do
    try do
      case GenServer.call(pid, :join, timeout) do
        {:ok, reply} ->
          {:ok, reply, pid}

        {:error, _} = error ->
          Phoenix.SocketClient.update_channel_status(sup_pid, pid, topic, :errored, params)
          GenServer.stop(pid)
          error
      end
    catch
      :exit, {:timeout, _} ->
        Phoenix.SocketClient.update_channel_status(sup_pid, pid, topic, :errored, params)
        GenServer.stop(pid, :normal)
        {:error, :timeout}

      :exit, {:noproc, _} ->
        Phoenix.SocketClient.update_channel_status(sup_pid, pid, topic, :errored, params)
        GenServer.stop(pid, :normal)
        {:error, :noproc}

      :exit, reason ->
        Phoenix.SocketClient.update_channel_status(sup_pid, pid, topic, :errored, params)
        GenServer.stop(pid, :normal)
        {:error, exit_reason(reason)}
    end
  end

  defp exit_reason({:timeout, _}), do: :timeout
  defp exit_reason(reason), do: reason
end
