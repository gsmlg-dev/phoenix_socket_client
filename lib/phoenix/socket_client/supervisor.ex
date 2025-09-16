defmodule Phoenix.SocketClient.Supervisor do
  import Phoenix.SocketClient, only: [connect: 1, get_state: 2]

  use Supervisor

  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name)

    if is_nil(name) do
      Supervisor.start_link(__MODULE__, opts)
    else
      Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    sup_pid = self()
    opts = opts |> Map.put(:sup_pid, sup_pid)

    children = [
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
