defmodule EtherCAT.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {EtherCAT.Master, []}
    ]

    opts = [strategy: :one_for_one, name: EtherCAT.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
