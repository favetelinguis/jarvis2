defmodule Jarvis2.MCP.Identity do
  @moduledoc "Resolve advisory caller headers against a fresh session mirror."

  def resolve(headers) do
    mirror = Application.get_env(:jarvis2, :mirror, Jarvis2.Herdr.Mirror)
    resolve(headers, Jarvis2.Herdr.Mirror.get(mirror))
  end

  def resolve(headers, %{stale: false, snapshot: %{"panes" => panes, "agents" => agents}}) do
    pane_id = headers["x-herdr-pane"]
    workspace = headers["x-herdr-workspace"]
    pane = Enum.find(panes, &(&1["pane_id"] == pane_id and is_binary(pane_id)))

    if pane && is_binary(workspace) && workspace != "" && pane["workspace_id"] == workspace do
      agent = Enum.find(agents, &(&1["pane_id"] == pane_id)) || %{}

      %{
        workspace: pane["workspace_id"],
        tab: pane["tab_id"],
        pane: pane_id,
        agent_name: agent["name"],
        agent_kind: agent["agent"],
        cwd: pane["foreground_cwd"] || pane["cwd"]
      }
    else
      unknown()
    end
  end

  def resolve(_, _), do: unknown()

  defp unknown,
    do: %{
      workspace: "unknown",
      tab: nil,
      pane: "unknown",
      agent_name: nil,
      agent_kind: nil,
      cwd: nil
    }
end
