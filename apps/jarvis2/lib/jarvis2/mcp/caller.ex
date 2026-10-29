defmodule Jarvis2.MCP.Caller do
  @moduledoc """
  Who is calling an MCP tool. A run token identifies the run, and the run's recorded pane and
  terminal give its Herdr identity. The advisory `X-Herdr-*` headers are only a cross-check: a
  header pane that differs from the run's pane marks the caller as mismatched, and write tools
  refuse mismatched callers. The long-lived file token and plain headers keep working for agents
  that were not started as runs.
  """
  require Logger

  alias Jarvis2.Herdr.Mirror
  alias Jarvis2.MCP.Identity
  alias Jarvis2.{Runs, Tokens}
  alias Jarvis2.Runs.Launcher

  def resolve(headers) do
    case bearer(headers) do
      "j2r_" <> _ = token -> resolve_run(token, headers)
      _ -> Map.put(Identity.resolve(headers), :run_id, nil)
    end
  end

  def bearer(headers) do
    case headers["authorization"] do
      "Bearer " <> token -> token
      _ -> nil
    end
  end

  defp resolve_run(token, headers) do
    with {:ok, run_id} <- Tokens.resolve(token),
         %Runs.Run{} = run <- Runs.get_run(run_id) do
      view = view()
      from_headers = Identity.resolve(headers, view)
      base = run_identity(run, view)

      mismatch =
        from_headers.pane != "unknown" and run.pane_id != nil and from_headers.pane != run.pane_id

      if mismatch, do: Logger.warning("run caller pane header mismatch run=#{run.id}")
      Map.merge(base, %{run_id: run.id, mismatch: mismatch})
    else
      _ -> Map.put(Identity.resolve(%{}, nil), :run_id, nil)
    end
  end

  defp run_identity(run, view) do
    case Launcher.find(run, view) do
      {pane, _agent} ->
        Identity.resolve(
          %{"x-herdr-pane" => run.pane_id, "x-herdr-workspace" => pane["workspace_id"]},
          view
        )

      nil ->
        Identity.resolve(%{}, view)
    end
  end

  defp view do
    Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))
  catch
    :exit, _ -> nil
  end
end
