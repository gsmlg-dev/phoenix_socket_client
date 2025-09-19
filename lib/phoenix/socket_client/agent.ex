defmodule Phoenix.SocketClient.Agent do
  @moduledoc """
  Agent-based state management for WebSocket connection configuration and status.

  This module provides centralized state management for socket connections,
  including configuration parameters, connection status, and custom state values.
  All state is stored in an Agent process for concurrent access and updates.

  The state is managed by the `Phoenix.SocketClient.State` struct.
  """

  use Agent

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

  def update_channel_status(pid, sup_pid, channel_pid, topic, status, params \\ nil) do
    Agent.update(pid, fn state ->
      channel_data = Map.get(state.joined_channels, topic, %{})
      old_status = Map.get(channel_data, :status)

      new_channel_data =
        if params do
          Map.put(channel_data, :params, params)
        else
          channel_data
        end
        |> Map.put(:status, status)

      joined_channels = Map.put(state.joined_channels, topic, new_channel_data)

      socket_pid = Phoenix.SocketClient.get_process_pid(sup_pid, :socket)
      Phoenix.SocketClient.Telemetry.channel_status_changed(socket_pid, topic, channel_pid, old_status, status)

      %State{state | joined_channels: joined_channels}
    end)
  end

  def reconfigure(pid, new_opts) do
    Agent.get_and_update(pid, fn old_state ->
      new_opts_map = Enum.into(new_opts, %{})
      merged_config = Map.merge(Map.from_struct(old_state), old_state.custom) |> Map.merge(new_opts_map)
      new_state = prepare_state(merged_config)

      connection_keys = [
        :url,
        :params,
        :headers,
        :transport,
        :transport_opts,
        :vsn,
        :heartbeat_interval
      ]

      old_map = Map.from_struct(old_state) |> Map.merge(old_state.custom)
      new_map = Map.from_struct(new_state) |> Map.merge(new_state.custom)

      restart_needed =
        Enum.any?(connection_keys, fn key ->
          Map.get(old_map, key) != Map.get(new_map, key)
        end)

      {restart_needed, new_state}
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
    prepare_state(config)
  end

  def prepare_state(config) do
    custom_opts = Map.drop(config, Map.keys(State.__struct__()))
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

    serializer = Phoenix.SocketClient.Message.serializer(config.vsn)

    struct(State, Map.to_list(config) ++ [url: base_url, transport_opts: transport_opts, serializer: serializer])
  end
end
