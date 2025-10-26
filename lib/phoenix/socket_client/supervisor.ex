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
      |> Enum.map_join(&String.capitalize/1)
      |> (&(&1 <> "ChannelRegistry")).()
      |> String.to_atom()

    registry_name = Map.get(opts, :registry_name, default_registry_name)

    # Get serializer from opts for MessageProcessor
    serializer = Phoenix.SocketClient.Message.serializer(Map.get(opts, :vsn, "2.0.0"))
    opts = opts |> Map.put(:registry_name, registry_name) |> Map.put(:serializer, serializer)

    children = [
      {Registry, keys: :unique, name: registry_name},
      {Phoenix.SocketClient.Agent, opts}
      |> Supervisor.child_spec(id: :socket_state),
      {Phoenix.SocketClient.HibernationManager, opts}
      |> Supervisor.child_spec(id: :hibernation_manager),
      {Phoenix.SocketClient.RouteCache, opts}
      |> Supervisor.child_spec(id: :route_cache),
      {Phoenix.SocketClient.MessageProcessor, opts}
      |> Supervisor.child_spec(id: :message_processor),
      {Phoenix.SocketClient.Socket, opts}
      |> Supervisor.child_spec(id: :socket),
      {Phoenix.SocketClient.ChannelManager, opts}
      |> Supervisor.child_spec(id: :channel_manager),
      {Task,
       fn ->
         # Store registry name in agent state for fast access
         case Phoenix.SocketClient.get_process_pid(sup_pid, :socket_state) do
           nil -> :ok
           state_pid -> Phoenix.SocketClient.Agent.put(state_pid, :registry_name, registry_name)
         end

         # Register socket process with hibernation manager
         case Phoenix.SocketClient.get_process_pid(sup_pid, :socket) do
           nil ->
             :ok

           socket_pid ->
             Phoenix.SocketClient.HibernationManager.register_process(
               socket_pid,
               {registry_name, :socket}
             )
         end

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
