defmodule Jarvis2.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    path = herdr_path()
    children = Jarvis2.Core.child_specs(path: path)

    children =
      if Application.get_env(:jarvis2, :automations, true) do
        children ++ Jarvis2.Automations.child_specs()
      else
        children
      end

    children =
      if Application.get_env(:jarvis2, :events, true) do
        if is_nil(path), do: raise("Herdr events require a configured session")
        children ++ [{Jarvis2.Herdr.Events, path: path}]
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

  defp herdr_path do
    case Application.get_env(:jarvis2, :herdr_session) do
      nil ->
        nil

      name ->
        case Jarvis2.Herdr.Session.ensure(name) do
          {:ok, path} -> path
          {:error, reason} -> raise "Unable to ensure Herdr session #{inspect(name)}: #{reason}"
        end
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
