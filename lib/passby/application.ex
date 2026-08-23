defmodule Passby.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Passby.InstanceSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Passby.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
