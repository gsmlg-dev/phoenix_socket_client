defmodule PhoenixSocketClient.Channel do
  use GenServer

  alias PhoenixSocketClient.{Socket, Message, Telemetry}

  @timeout 5_000

  @doc false
  def child_spec(args) do
    %{
      id: elem(args, 1),
      start: {__MODULE__, :start_link, [args]}
    }
  end

  @doc false
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: via_tuple(elem(args, 1)))
  end

  defp via_tuple(topic) do
    {:via, Registry, {Registry.Connection, topic}}
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
  def join(socket_pid_or_name, topic, params \\ %{}, timeout \\ @timeout)
  def join(nil, _topic, _params, _timeout), do: {:error, :socket_not_started}

  def join(socket_pid_or_name, topic, params, timeout) do
    if Process.whereis(socket_pid_or_name) |> is_pid() and Socket.connected?(socket_pid_or_name) do
      case Socket.channel_join(socket_pid_or_name, topic, params) do
        {:ok, pid} -> do_join(pid, timeout)
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
  @spec push(pid, binary, map, non_neg_integer) :: term()
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

  # Callbacks
  @impl true
  def init({socket, topic, params}) do
    {:ok,
     %{
       caller: nil,
       socket: socket,
       topic: topic,
       params: params,
       pushes: [],
       join_ref: nil
     }}
  end

  @impl true
  def handle_call(
        :join,
        from,
        %{socket: socket, topic: topic, params: params} = state
      ) do
    message = Message.join(topic, params)

    # Find the actual socket process
    socket_pid = PhoenixSocketClient.Socket.resolve_socket_pid(socket)

    case socket_pid do
      nil ->
        {:reply, {:error, :socket_not_found}, state}

      pid ->
        push = Socket.push(pid, message)
        Telemetry.channel_joined(self(), topic, nil, %{}, %{params: params})

        {:noreply,
         %{
           state
           | join_ref: push.ref,
             caller: elem(from, 0),
             pushes: [{from, push} | state.pushes]
         }}
    end
  end

  @impl true
  def handle_call(:leave, _from, state) do
    send(self(), :shutdown)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:push, event, payload}, from, %{socket: socket, topic: topic} = state) do
    message = %Message{
      topic: topic,
      event: event,
      payload: payload,
      ref: Message.generate_ref(),
      join_ref: state.join_ref
    }

    push = Socket.push(socket, message)
    Telemetry.message_sent(self(), topic, event, payload)
    {:noreply, %{state | pushes: [{from, push} | state.pushes]}}
  end

  @impl true
  def handle_cast({:push, event, payload}, %{socket: socket, topic: topic} = state) do
    message = %Message{
      topic: topic,
      event: event,
      payload: payload,
      channel_pid: self(),
      join_ref: state.join_ref
    }

    Socket.push(socket, message)
    Telemetry.message_sent(self(), topic, event, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info(:shutdown, %{socket: socket, topic: topic} = state) do
    Socket.channel_leave(socket, self())
    Telemetry.channel_left(self(), topic, :leave)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(
        %Message{event: "phx_reply", ref: ref} = msg,
        %{pushes: pushes, topic: topic} = s
      ) do
    pushes =
      case Enum.split_with(pushes, &(elem(&1, 1).ref == ref)) do
        {[{from_ref, _push}], pushes} ->
          %{"status" => status, "response" => response} = msg.payload

          case status do
            "ok" ->
              Telemetry.message_received(self(), topic, "phx_reply", msg.payload)

            "error" ->
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

    {:noreply, %{s | pushes: pushes}}
  end

  @impl true
  def handle_info(%Message{} = message, %{caller: pid, topic: topic} = state) do
    Telemetry.message_received(self(), topic, message.event, message.payload)
    send(pid, %{message | channel_pid: pid, topic: topic})
    {:noreply, state}
  end

  defp do_join(pid, timeout) do
    try do
      case GenServer.call(pid, :join, timeout) do
        {:ok, reply} ->
          {:ok, reply, pid}

        error ->
          GenServer.stop(pid)
          error
      end
    catch
      :exit, {:timeout, _} ->
        GenServer.stop(pid, :normal)
        {:error, :timeout}

      :exit, {:noproc, _} ->
        GenServer.stop(pid, :normal)
        {:error, :noproc}

      :exit, reason ->
        GenServer.stop(pid, :normal)
        {:error, exit_reason(reason)}
    end
  end

  defp exit_reason({:timeout, _}), do: :timeout
  defp exit_reason(reason), do: reason
end
