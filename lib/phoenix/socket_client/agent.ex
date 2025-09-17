defmodule Phoenix.SocketClient.Agent do
  @moduledoc """
  Agent-based state management for WebSocket connection configuration and status.

  This module provides centralized state management for socket connections,
  including configuration parameters, connection status, and custom state values.
  All state is stored in an Agent process for concurrent access and updates.

  The state is managed by the `Phoenix.SocketClient.State` struct.
  """

  use Agent

  alias Phoenix.SocketClient.Message
  alias Phoenix.SocketClient.State

  @heartbeat_interval 30_000
  @reconnect_interval 60_000
  @default_transport Phoenix.SocketClient.Transports.Websocket

  @doc """
  Starts the Agent with the given configuration options.

  ## Parameters
    * `opts` - Keyword list or map of configuration options

  ## Examples
      {:ok, pid} = Phoenix.SocketClient.Agent.start_link(url: "ws://localhost:4000/socket")
  """
  @spec start_link(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: Map.to_list(opts)
    Agent.start_link(fn -> init_state(opts) end)
  end

  @doc """
  Retrieves a value from the state by key.

  ## Parameters
    * `pid` - The Agent PID
    * `key` - The key to retrieve

  ## Examples
      value = Phoenix.SocketClient.Agent.get(pid, :url)
  """
  @spec get(pid(), atom() | String.t()) :: any()
  def get(pid, key) do
    Agent.get(pid, fn state ->
      Map.get(state, key, Map.get(state.custom, key))
    end)
  end

  def get_state(pid) do
    Agent.get(pid, & &1)
  end

  @doc """
  Updates the state with a new key-value pair.

  ## Parameters
    * `pid` - The Agent PID
    * `key` - The key to set
    * `value` - The value to associate with the key

  ## Examples
      :ok = Phoenix.SocketClient.Agent.put(pid, :status, :connected)
  """
  @spec put(pid(), atom() | String.t(), any()) :: :ok
  def put(pid, key, value) do
    Agent.update(pid, fn state ->
      if Map.has_key?(state, key) do
        Map.put(state, key, value)
      else
        custom = Map.put(state.custom, key, value)
        %State{state | custom: custom}
      end
    end)
  end

  def connected(pid) do
    get(pid, :status) == :connected
  end

  def pop_all_to_send(pid) do
    Agent.get_and_update(pid, fn state ->
      to_send = state.to_send_r |> Enum.reverse()
      {to_send, %State{state | to_send_r: []}}
    end)
  end

  def update_channel_status(pid, topic, status, params \\ nil) do
    Agent.update(pid, fn state ->
      channel_data = Map.get(state.joined_channels, topic, %{})

      new_channel_data =
        if params do
          Map.put(channel_data, :params, params)
        else
          channel_data
        end
        |> Map.put(:status, status)

      joined_channels = Map.put(state.joined_channels, topic, new_channel_data)
      %State{state | joined_channels: joined_channels}
    end)
  end

  def remove_channel(pid, topic) do
    Agent.update(pid, fn state ->
      joined_channels = Map.delete(state.joined_channels, topic)
      %State{state | joined_channels: joined_channels}
    end)
  end

  defp init_state(opts) do
    defaults = %{
      json_library: Jason,
      reconnect: true,
      auto_connect: true,
      vsn: "2.0.0",
      url: "ws://localhost:4000/socket/websocket",
      params: %{},
      headers: [],
      heartbeat_interval: @heartbeat_interval,
      reconnect_interval: @reconnect_interval,
      transport: @default_transport,
      transport_opts: [],
      sup_pid: nil,
      reconnect_timer: nil,
      status: :disconnected,
      transport_pid: nil,
      to_send_r: [],
      ref: 0,
      custom: %{},
      registry_name: Registry.Channel
    }

    config = Map.merge(defaults, Enum.into(opts, %{}))
    custom_opts = Map.drop(config, Map.keys(defaults))
    config = Map.put(config, :custom, custom_opts)

    url = config.url
    uri = URI.parse(url)
    query_params = Map.merge(%{"vsn" => config.vsn}, config.params)
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

    transport_opts =
      config.transport_opts
      |> Keyword.put_new(:extra_headers, config.headers)
      |> Keyword.put_new(:keepalive, config.heartbeat_interval)

    %State{
      url: base_url,
      json_library: config.json_library,
      params: config.params,
      vsn: config.vsn,
      auto_connect: config.auto_connect,
      reconnect: config.reconnect,
      reconnect_interval: config.reconnect_interval,
      reconnect_timer: config.reconnect_timer,
      status: config.status,
      serializer: Message.serializer(config.vsn),
      transport: config.transport,
      transport_opts: transport_opts,
      transport_pid: config.transport_pid,
      to_send_r: config.to_send_r,
      ref: config.ref,
      sup_pid: config.sup_pid,
      headers: config.headers,
      custom: config.custom,
      registry_name: config.registry_name
    }
  end
end
