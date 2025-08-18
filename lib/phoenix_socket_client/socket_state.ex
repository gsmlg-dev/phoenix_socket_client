defmodule PhoenixSocketClient.SocketState do
  use Agent

  alias PhoenixSocketClient.Message

  @heartbeat_interval 30_000
  @reconnect_interval 60_000
  @default_transport PhoenixSocketClient.Transports.Websocket

  def start_link({_server_pid, opts}) do
    Agent.start_link(fn -> init(opts) end)
  end

  def whereis(id) when is_atom(id) do
    case Process.whereis(id) do
      nil -> nil
      server_pid -> PhoenixSocketClient.get_process_pid(server_pid, :socket_state)
    end
  end

  def whereis(server_pid) when is_pid(server_pid) do
    PhoenixSocketClient.get_process_pid(server_pid, :socket_state)
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

  @doc """
  Returns the pid for the socket state process.
  """
  def whereis(id) do
    PhoenixSocketClient.get_process_pid(id, :socket_state)
  end

  def pop_all_to_send(pid) do
    Agent.get_and_update(pid, fn state ->
      to_send = state.to_send_r |> Enum.reverse()
      {to_send, %{state | to_send_r: []}}
    end)
  end

  defp init(opts) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    transport = Keyword.get(opts, :transport, @default_transport)
    json_library = Keyword.get(opts, :json_library, Jason)
    reconnect? = Keyword.get(opts, :reconnect?, true)

    protocol_vsn = Keyword.get(opts, :vsn, "2.0.0")
    serializer = Message.serializer(protocol_vsn)

    url =
      case Keyword.get(opts, :url) do
        nil -> "ws://localhost:4000/ws/websocket"
        "" -> "ws://localhost:4000/ws/websocket"
        url -> url
      end

    uri = URI.parse(url)

    params = Keyword.get(opts, :params, %{}) || %{}

    query_params = Map.merge(%{"vsn" => protocol_vsn}, params)
    query = URI.encode_query(query_params)

    # Construct final URL properly - ensure we always have a valid base URL
    base_url =
      if uri.query do
        # If URL already has query params, preserve them
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

    opts = Keyword.put_new(opts, :headers, [])
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval, @heartbeat_interval)
    reconnect_interval = Keyword.get(opts, :reconnect_interval, @reconnect_interval)

    transport_opts =
      Keyword.get(opts, :transport_opts, [])
      |> Keyword.put(:extra_headers, Keyword.get(opts, :headers))
      |> Keyword.put(:keepalive, heartbeat_interval)

    %{
      opts: opts,
      url: base_url,
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
end
