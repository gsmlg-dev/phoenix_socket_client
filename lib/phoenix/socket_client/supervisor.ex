defmodule Phoenix.SocketClient.Supervisor do
  @moduledoc """
  The main supervisor for the Phoenix Socket Client.
  """
  use Supervisor

  alias Phoenix.SocketClient.ConfigStore

  def child_spec(opts) do
    {:ok, config} = ConfigStore.new(opts)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{:supervised, config}]},
      type: :supervisor
    }
  end

  @doc """
  Releases the private configuration of a child specification that will not be started.

  Returns `{:error, :in_use}` once a supervising parent has activated the specification.
  Activated configuration is retained until that parent exits, including across
  client restarts.
  """
  @spec discard_child_spec(Supervisor.child_spec()) :: :ok | {:error, :in_use}
  def discard_child_spec(%{start: {__MODULE__, :start_link, [{:supervised, config}]}}),
    do: ConfigStore.discard(config)

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
    * `:json_library` - The JSON encoder/decoder module to use.
    * `:vsn` - The Phoenix Channels protocol version.
    * `:topic_channel_map` - A map from a topic string to a channel module.
    * `:default_channel_module` - The default channel module to use.
    * `:default_channel_params` - The default parameters to use for channels.

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    {:ok, config} = ConfigStore.new(opts)

    case start_with_config(config) do
      {:ok, pid} = result ->
        :ok = ConfigStore.bind_owner(config, pid)
        result

      error ->
        ConfigStore.close(config)
        error
    end
  end

  def start_link({:supervised, config}) do
    with :ok <- ConfigStore.bind_owner(config, self()) do
      start_with_config(config)
    end
  end

  defp start_with_config(config) do
    opts = ConfigStore.options(config)
    name = Keyword.get(opts, :name, Phoenix.SocketClient)
    Supervisor.start_link(__MODULE__, config, name: name)
  catch
    _kind, _private_reason -> {:error, :private_callback_failure}
  end

  @impl true
  def init(config) do
    Phoenix.SocketClient.Privacy.run(fn -> init_private(config) end)
  end

  defp init_private(config) do
    opts = ConfigStore.options(config)
    name = Keyword.get(opts, :name, Phoenix.SocketClient)
    opts = opts |> Keyword.put(:name, name) |> Keyword.put(:private_config, config)
    sup_pid = self()
    opts = Keyword.put(opts, :sup_pid, sup_pid)

    name = Keyword.get(opts, :name)

    default_registry_name =
      name
      |> to_string()
      |> String.replace_leading("Elixir.", "")
      |> String.split(["_", "."])
      |> Enum.map_join(&String.capitalize/1)
      |> (&(&1 <> "ChannelRegistry")).()
      |> String.to_atom()

    registry_name = Keyword.get(opts, :registry_name, default_registry_name)
    true = is_atom(registry_name)

    # Get serializer from opts for MessageProcessor
    serializer = Phoenix.SocketClient.Message.serializer(Keyword.get(opts, :vsn, "2.0.0"))

    opts =
      opts |> Keyword.put(:registry_name, registry_name) |> Keyword.put(:serializer, serializer)

    :ok = ConfigStore.put_options(config, opts)

    children = [
      {Registry, keys: :unique, name: registry_name},
      private_child(Phoenix.SocketClient.Agent, opts, config, :socket_state),
      private_child(Phoenix.SocketClient.HibernationManager, opts, config, :hibernation_manager),
      private_child(Phoenix.SocketClient.RouteCache, opts, config, :route_cache),
      private_child(Phoenix.SocketClient.MessageProcessor, opts, config, :message_processor),
      private_child(Phoenix.SocketClient.Socket, opts, config, :socket),
      private_child(Phoenix.SocketClient.ChannelManager, opts, config, :channel_manager),
      {Task,
       fn ->
         # Store registry name in agent state for fast access
         case Phoenix.SocketClient.get_process_pid(sup_pid, :socket_state) do
           nil -> :ok
           state_pid -> Phoenix.SocketClient.Agent.put(state_pid, :registry_name, registry_name)
         end

         # Register socket process with hibernation manager
         case {Phoenix.SocketClient.get_process_pid(sup_pid, :hibernation_manager),
               Phoenix.SocketClient.get_process_pid(sup_pid, :socket)} do
           {nil, _} ->
             :ok

           {_, nil} ->
             :ok

           {hm_pid, socket_pid} ->
             Phoenix.SocketClient.HibernationManager.register_process(
               hm_pid,
               socket_pid,
               {registry_name, :socket}
             )
         end
       end}
      |> Supervisor.child_spec(id: :post_start)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp private_child(module, opts, config, id) do
    spec = Supervisor.child_spec({module, opts}, id: id)
    %{spec | start: {ConfigStore, :start_child, [module, config]}}
  end
end
