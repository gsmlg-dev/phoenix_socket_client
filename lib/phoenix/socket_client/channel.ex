defmodule Phoenix.SocketClient.Channel do
  @moduledoc """
  A process for interacting with a Phoenix Channel.
  """

  alias Phoenix.SocketClient.Channel.State

  @typedoc """
  The state of the channel.
  """
  @type state :: %State{}

  @doc """
  Callback for handling incoming messages.
  """
  @callback handle_message(event :: String.t(), payload :: map(), state :: state()) ::
              {:noreply, new_state :: state()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Phoenix.SocketClient.Channel
      use GenServer
      alias Phoenix.SocketClient.Channel.{Helpers, State}
      alias Phoenix.SocketClient.Message

      @doc false
      def start_link(args) do
        GenServer.start_link(__MODULE__, args)
      end

      # Callbacks - delegate to Helpers module
      @impl true
      def init(args), do: Helpers.init_impl(args)

      @impl true
      def handle_call(:join, from, state), do: Helpers.handle_join_call(from, state)

      @impl true
      def handle_call(:leave, from, state), do: Helpers.handle_leave_call(from, state)

      @impl true
      def handle_call({:push, event, payload}, from, state),
        do: Helpers.handle_push_call({event, payload}, from, state)

      @impl true
      def handle_call(:get_topic, from, state), do: Helpers.handle_get_topic_call(from, state)

      @impl true
      def handle_cast({:push, event, payload}, state),
        do: Helpers.handle_push_cast({event, payload}, state)

      @impl true
      def handle_info(%Message{event: "phx_reply"} = msg, state),
        do: Helpers.handle_phx_reply_info(msg, state, &handle_message/3)

      @impl true
      def handle_info(%Message{} = message, state),
        do: Helpers.handle_message_info(message, state, &handle_message/3)

      @impl true
      def terminate(reason, state), do: Helpers.terminate_impl(reason, state)

      defoverridable init: 1,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     terminate: 2
    end
  end

  @timeout 5_000

  @doc """
  Stops the channel process.
  """
  @spec stop(pid) :: :ok
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
          {:ok, any, pid}
          | {:error, :socket_not_connected}
          | {:error, :timeout}
          | {:error, {:already_joined, pid}}
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
  Push a message to the server and wait for a a response or timeout

  The server must be configured to return `{:reply, _, socket}`
  otherwise, the call will timeout.
  """
  @spec push(pid, binary, map, non_neg_integer) ::
          {:ok, any} | {:error, any | :timeout}
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
