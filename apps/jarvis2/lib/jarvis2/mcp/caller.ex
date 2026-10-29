defmodule Jarvis2.MCP.Caller do
  @moduledoc "Resolve the caller's pane headers and its active run. Headers are not authenticated."

  alias Jarvis2.Herdr.Mirror
  alias Jarvis2.MCP.Identity
  alias Jarvis2.Runs
  alias Jarvis2.Runs.Launcher

  def resolve(headers) do
    view = view()
    run = Runs.get_active_by_pane(headers["x-herdr-pane"])
    run = if valid_terminal?(run, view), do: run
    Map.put(Identity.resolve(headers, view), :run_id, run && run.id)
  end

  defp valid_terminal?(nil, _view), do: false

  defp valid_terminal?(run, %{stale: false, snapshot: %{"panes" => panes}} = view)
       when is_list(panes),
       do: Launcher.find(run, view) != nil

  defp valid_terminal?(_run, _view), do: true

  defp view do
    Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))
  catch
    :exit, _ -> nil
  end
end
