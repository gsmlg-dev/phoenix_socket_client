defmodule PhoenixSocketClient.Socket.State do
  use Agent

  alias PhoenixSocketClient.Message

  @heartbeat_interval 30_000
  @reconnect_interval 60_000
  @default_transport PhoenixSocketClient.Transports.Websocket

  def start_link(opts) do
    Agent.start_link(fn -> init(opts) end, name: agent_name(opts[:id]))
  end

  def whereis(id) do
    Process.whereis(agent_name(id))
  end

  def get(pid, key) do
    Agent.get(pid, &Map.get(&1, key))
  end

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

  def push_message(pid, message) do
    Agent.get_and_update(pid, fn state ->
      ref = state.ref + 1
      push = %{message | ref: to_string(ref)}
      state = %{state | ref: ref, to_send_r: [push | state.to_send_r]}
      {push, state}
    end)
  end

  defp init(opts) do
    transport = opts[:transport] || @default_transport

    json_library = Keyword.get(opts, :json_library, Jason)
    reconnect? = Keyword.get(opts, :reconnect?, true)

    protocol_vsn = Keyword.get(opts, :vsn, "2.0.0")
    serializer = Message.serializer(protocol_vsn)

    uri =
      opts
      |> Keyword.get(:url, "")
      |> URI.parse()

    params = Keyword.get(opts, :params, %{})

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("vsn", protocol_vsn)
      |> Map.merge(params)
      |> URI.encode_query()

    url =
      uri
      |> Map.put(:query, query)
      |> to_string()

    opts = Keyword.put_new(opts, :headers, [])
    heartbeat_interval = opts[:heartbeat_interval] || @heartbeat_interval
    reconnect_interval = opts[:reconnect_interval] || @reconnect_interval

    transport_opts =
      Keyword.get(opts, :transport_opts, [])
      |> Keyword.put(:extra_headers, Keyword.get(opts, :headers))
      |> Keyword.put(:keepalive, heartbeat_interval)

    %{
      opts: opts,
      url: url,
      json_library: json_library,
      params: params,
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
  end

  defp agent_name(id) do
    Module.concat(__MODULE__, id)
  end
end
