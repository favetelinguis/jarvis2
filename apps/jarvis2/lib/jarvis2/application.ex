defmodule Jarvis2.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = Jarvis2.Core.child_specs()

    children =
      if Application.get_env(:jarvis2, :automations, true) do
        children ++ Jarvis2.Automations.child_specs()
      else
        children
      end

    children =
      if Application.get_env(:jarvis2, :events, true) do
        children ++ [Jarvis2.Herdr.Events]
      else
        children
      end

    children =
      if Application.get_env(:jarvis2, :run_monitor, true),
        do: children ++ [Jarvis2.Runs.Monitor],
        else: children

    children = children ++ Jarvis2.MCP.child_specs() ++ [Jarvis2Web.Endpoint]

    with {:ok, _} = started <-
           Supervisor.start_link(children, strategy: :rest_for_one, name: Jarvis2.Supervisor) do
      if Application.get_env(:jarvis2, :apply_settings, true),
        do: Jarvis2.Settings.apply_settings()

      announce_login()
      started
    end
  end

  # Printed to stdout rather than logged so the single-use code stays out of log files.
  defp announce_login do
    endpoint = Application.get_env(:jarvis2, Jarvis2Web.Endpoint, [])

    if endpoint[:server] do
      port = get_in(endpoint, [:http, :port])
      code = Jarvis2.LoginCodes.issue()
      IO.puts("Jarvis2 UI: http://127.0.0.1:#{port}/login?code=#{code}  (single use, 10 minutes)")
    end
  end
end
