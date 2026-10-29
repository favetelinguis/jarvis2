defmodule Jarvis2.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = Jarvis2.Core.child_specs()

    children =
      if Application.get_env(:jarvis2, :scenarios, true) do
        children ++ Jarvis2.Scenarios.child_specs()
      else
        children
      end

    children =
      if Application.get_env(:jarvis2, :events, true) do
        children ++ [Jarvis2.Herdr.Events]
      else
        children
      end

    children = children ++ Jarvis2.MCP.child_specs()

    children =
      if Application.get_env(:jarvis2, :serve, true) do
        children ++
          [
            {Bandit,
             plug: Jarvis2.Web.Router,
             ip: {127, 0, 0, 1},
             port: Application.get_env(:jarvis2, :port, 4747)}
          ]
      else
        children
      end

    Supervisor.start_link(children, strategy: :rest_for_one, name: Jarvis2.Supervisor)
  end
end
