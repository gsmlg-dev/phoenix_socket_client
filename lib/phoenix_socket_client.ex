defmodule PhoenixSocketClient do
  @moduledoc """
  A Supervisor for starting, supervising, and managing socket connections.
  """
  use Supervisor

  alias PhoenixSocketClient.Socket

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {PhoenixSocketClient.SocketState, opts},
      {Socket, opts},
      {ChannelManager, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Starts a new socket connection.
  """
  def start_socket(supervisor, opts) do
    id = Keyword.fetch!(opts, :id)

    spec = %{
      id: id,
      start: {Socket, :start_link, [opts, [name: id]]}
    }

    Supervisor.start_child(supervisor, spec)
  end
end
