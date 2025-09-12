defmodule Phoenix.SocketClient.SocketState do
  @moduledoc """
  Agent-based state management for WebSocket connection configuration and status.

  This module provides centralized state management for socket connections,
  including configuration parameters, connection status, and custom state values.
  All state is stored in an Agent process for concurrent access and updates.

  ## State Structure

  The state is a map that includes:
  - `:url` - WebSocket URL
  - `:params` - Connection parameters
  - `:headers` - HTTP headers
  - `:serializer` - JSON serializer module
  - `:transport` - Transport module
  - `:status` - Connection status (:disconnected, :connecting, :connected)
  - `:heartbeat_interval` - Heartbeat interval in milliseconds
  - `:reconnect_interval` - Reconnection interval in milliseconds
  - `:auto_connect` - Whether to auto-connect on startup
  - Custom state values added by users
  """

  use Agent

  alias Phoenix.SocketClient.Message

  @heartbeat_interval 30_000
  @reconnect_interval 60_000
  @default_transport Phoenix.SocketClient.Transports.Websocket

  @doc """
  Starts the SocketState agent with the given configuration options.

  ## Parameters
    * `opts` - Keyword list or map of configuration options

  ## Examples
      {:ok, pid} = Phoenix.SocketClient.SocketState.start_link(url: "ws://localhost:4000/socket")
  """
  @spec start_link(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: Map.to_list(opts)
    Agent.start_link(fn -> init_state(opts) end)
  end

  @doc """
  Retrieves a value from the state by key.

  ## Parameters
    * `pid` - The SocketState agent PID
    * `key` - The key to retrieve

  ## Examples
      value = Phoenix.SocketClient.SocketState.get(pid, :url)
  """
  @spec get(pid(), atom() | String.t()) :: any()
  def get(pid, key) do
    Agent.get(pid, &Map.get(&1, key))
  end

  @doc """
  Updates the state with a new key-value pair.

  ## Parameters
    * `pid` - The SocketState agent PID
    * `key` - The key to set
    * `value` - The value to associate with the key

  ## Examples
      :ok = Phoenix.SocketClient.SocketState.put(pid, :custom_key, "custom_value")
  """
  @spec put(pid(), atom() | String.t(), any()) :: :ok
  def put(pid, key, value) do
    Agent.update(pid, &Map.put(&1, key, value))
  end

  def connected(pid) do
    get(pid, :status) == :connected
  end

  def pop_all_to_send(pid) do
    Agent.get_and_update(pid, fn state ->
      to_send = state.to_send_r |> Enum.reverse()
      {to_send, %{state | to_send_r: []}}
    end)
  end

  defp init_state(opts) do
    transport = Keyword.get(opts, :transport, @default_transport)
    json_library = Keyword.get(opts, :json_library, Jason)
    reconnect? = Keyword.get(opts, :reconnect?, true)
    auto_connect = Keyword.get(opts, :auto_connect, true)
    protocol_vsn = Keyword.get(opts, :vsn, "2.0.0")
    serializer = Message.serializer(protocol_vsn)
    url = Keyword.get(opts, :url, "ws://localhost:4000/socket/websocket")
    uri = URI.parse(url)
    params = Keyword.get(opts, :params, %{})
    query_params = Map.merge(%{"vsn" => protocol_vsn}, params)
    query = URI.encode_query(query_params)

    base_url =
      if uri.query do
        url_parts = String.split(url, "?", parts: 2)
        base = Enum.at(url_parts, 0)
        existing_query = Enum.at(url_parts, 1)

        if existing_query && String.trim(existing_query) != "" do
          base <> "?" <> existing_query <> "&" <> query
        else
          base <> "?" <> query
        end
      else
        url <> "?" <> query
      end

    heartbeat_interval = Keyword.get(opts, :heartbeat_interval, @heartbeat_interval)
    reconnect_interval = Keyword.get(opts, :reconnect_interval, @reconnect_interval)

    transport_opts =
      Keyword.get(opts, :transport_opts, [])
      |> Keyword.put(:extra_headers, Keyword.get(opts, :headers, []))
      |> Keyword.put(:keepalive, heartbeat_interval)

    state = %{
      url: base_url,
      json_library: json_library,
      params: params,
      vsn: protocol_vsn,
      auto_connect: auto_connect,
      reconnect: reconnect?,
      reconnect_interval: reconnect_interval,
      reconnect_timer: nil,
      status: :disconnected,
      serializer: serializer,
      transport: transport,
      transport_opts: transport_opts,
      transport_pid: nil,
      to_send_r: [],
      ref: 0
    }

    Map.merge(Enum.into(opts, %{}), state)
  end
end
