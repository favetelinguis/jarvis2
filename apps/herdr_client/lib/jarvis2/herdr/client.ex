defmodule Jarvis2.Herdr.Client do
  @moduledoc "Read-only requests to Herdr. Mutations belong in `Jarvis2.Herdr.Actions`."
  alias Jarvis2.Herdr.Socket

  def snapshot(opts \\ []), do: Socket.request("session.snapshot", %{}, opts)
  def list_agents(opts \\ []), do: Socket.request("agent.list", %{}, opts)

  def export_layout(tab_id, opts \\ []),
    do: Socket.request("layout.export", %{tab_id: tab_id}, opts)

  def list_worktrees(workspace, opts \\ []),
    do: Socket.request("worktree.list", %{workspace_id: workspace}, opts)

  def read_agent(agent, opts \\ []) do
    params = %{target: agent, source: "recent_unwrapped", lines: Keyword.get(opts, :lines, 80)}
    Socket.request("agent.read", params, opts)
  end
end
