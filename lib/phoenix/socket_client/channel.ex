defmodule Phoenix.SocketClient.Channel do
  defmacro __using__(_opts) do
    quote do
      use GenServer

      @doc false
      def start_link(args) do
        GenServer.start_link(__MODULE__, args)
      end

      @impl true
      def init(args) do
        {:ok, args}
      end

      @impl true
      def handle_call(:join, _from, state) do
        {:reply, {:ok, %{}}, state}
      end

      defoverridable init: 1, handle_call: 3
    end
  end

  use GenServer

  alias Phoenix.SocketClient.{Message, Telemetry}

  @type t :: %__MODULE__{
          caller: pid() | nil,
          sup_pid: pid(),
          socket_pid: pid(),
          topic: String.t(),
          params: map(),
          pushes: list(),
          join_ref: String.t() | nil,
          hooks: map(),
          registry_name: atom()
        }

  defstruct caller: nil,
            sup_pid: nil,
            socket_pid: nil,
            topic: nil,
            params: %{},
            pushes: [],
            join_ref: nil,
            hooks: %{},
            registry_name: nil,
            join_start_time: nil,
            leave_start_time: nil

  @timeout 5_000

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

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

  @doc """
  Registers a callback for a specific event on the channel.

  The callback can be an anonymous function of arity 1, which will be called
  with the message payload.

  ## Examples

      on(channel, "new_msg", fn payload -> IO.inspect(payload) end)

  It can also be a module that implements `handle_in/2`, which will be
  called with the event and the payload.

  ## Examples

      defmodule MyHook do
        def handle_in(event, payload) do
          IO.puts("Got event \#{event} with payload \#{inspect payload}")
        end
      end

      on(channel, "new_msg", MyHook)
  """
  @spec on(pid, String.t(), (map() -> any()) | module()) :: :ok
  def on(pid, event, callback) when is_function(callback, 1) or is_atom(callback) do
    GenServer.cast(pid, {:on, event, callback})
  end

  @doc """
  Unregisters a callback for a specific event on the channel.
  """
  @spec off(pid, String.t()) :: :ok
  def off(pid, event) do
    GenServer.cast(pid, {:off, event})
  end

  # Callbacks
  @impl true
  @spec init({pid(), pid(), String.t(), map(), atom()}) :: {:ok, t()}
  def init({sup_pid, socket_pid, topic, params, registry_name}) do
    Registry.register(registry_name, topic, self())

    {:ok,
     %__MODULE__{
       sup_pid: sup_pid,
       socket_pid: socket_pid,
       topic: topic,
       params: params,
       registry_name: registry_name
     }}
  end

  @impl true
  @spec handle_call(:join, GenServer.from(), t()) :: {:noreply, t()}
  def handle_call(
        :join,
        {_pid, _ref} = from,
        %{sup_pid: sup_pid, topic: topic, params: params} = state
      ) do
    message = Message.join(topic, params)

    push = Phoenix.SocketClient.push(sup_pid, message)

    {:noreply,
     %__MODULE__{
       state
       | join_ref: push.ref,
         caller: elem(from, 0),
         pushes: [{from, push} | state.pushes],
         join_start_time: System.monotonic_time()
     }}
  end

  @impl true
  @spec handle_call(:leave, GenServer.from(), t()) :: {:stop, :normal, :ok, t()}
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
  @spec handle_call({:push, String.t(), map()}, GenServer.from(), t()) :: {:noreply, t()}
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
    {:noreply, %__MODULE__{state | pushes: [{from, push} | state.pushes]}}
  end

  @impl true
  @spec handle_cast({:on, String.t(), (map() -> any()) | module()}, t()) :: {:noreply, t()}
  def handle_cast({:on, event, callback}, state) do
    hooks = Map.put(state.hooks, event, callback)
    {:noreply, %__MODULE__{state | hooks: hooks}}
  end

  @impl true
  @spec handle_cast({:off, String.t()}, t()) :: {:noreply, t()}
  def handle_cast({:off, event}, state) do
    hooks = Map.delete(state.hooks, event)
    {:noreply, %__MODULE__{state | hooks: hooks}}
  end

  @impl true
  @spec handle_cast({:push, String.t(), map()}, t()) :: {:noreply, t()}
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
  @spec handle_info(Message.t(), t()) :: {:noreply, t()}
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

    {:noreply, %__MODULE__{s | pushes: pushes}}
  end

  @impl true
  @spec handle_info(Message.t(), t()) :: {:noreply, t()}
  def handle_info(%Message{} = message, state) do
    %{caller: pid, topic: topic, hooks: hooks} = state

    Telemetry.message_received(self(), topic, message.event, message.payload)

    case Map.get(hooks, message.event) do
      nil ->
        send(pid, %{message | channel_pid: pid, topic: topic})

      callback ->
        if is_function(callback) do
          callback.(message.payload)
        else
          callback.handle_in(message.event, message.payload)
        end
    end

    {:noreply, state}
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
