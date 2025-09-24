defmodule Phoenix.SocketClient.Supervisor do
  @moduledoc """
  The main supervisor for the Phoenix Socket Client.
  """
  import Phoenix.SocketClient, only: [connect: 1, get_state: 2]

  use Supervisor

  @doc """
  Starts the socket client supervisor.

  ## Options

    * `:name` - The name to register the supervisor.
    * `:url` - The WebSocket URL.
    * `:params` - The parameters to send on connection.
    * `:headers` - The headers to send on connection.
    * `:transport` - The transport to use.
    * `:heartbeat_interval` - The heartbeat interval in milliseconds.
    * `:reconnect_interval` - The reconnect interval in milliseconds.
    * `:reconnect?` - Whether to reconnect automatically.
    * `:auto_connect` - Whether to connect automatically on startup.
    * `:serializer` - The serializer to use.
    * `:vsn` - The Phoenix Channels protocol version.
    * `:topic_channel_map` - A map from a topic string to a channel module.
    * `:default_channel_module` - The default channel module to use.
    * `:default_channel_params` - The default parameters to use for channels.

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, Phoenix.SocketClient)
    opts = Map.put(opts, :name, name)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    sup_pid = self()
    opts = opts |> Map.put(:sup_pid, sup_pid)

    name = Map.get(opts, :name)

    default_registry_name =
      name
      |> to_string()
      |> String.replace_leading("Elixir.", "")
      |> String.split(["_", "."])
      |> Enum.map(&String.capitalize/1)
      |> Enum.join()
      |> (&(&1 <> "ChannelRegistry")).()
      |> String.to_atom()

    registry_name = Map.get(opts, :registry_name, default_registry_name)

    opts = opts |> Map.put(:registry_name, registry_name)

    children = [
      {Registry, keys: :unique, name: registry_name},
      {Phoenix.SocketClient.Agent, opts}
      |> Supervisor.child_spec(id: :socket_state),
      {Phoenix.SocketClient.Socket, opts}
      |> Supervisor.child_spec(id: :socket),
      {Phoenix.SocketClient.ChannelManager, opts}
      |> Supervisor.child_spec(id: :channel_manager),
      {Task,
       fn ->
         if get_state(sup_pid, :auto_connect) do
           Process.sleep(1_000)
           connect(sup_pid)
         end
       end}
      |> Supervisor.child_spec(id: :post_start)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
