defmodule Jarvis2.Scenarios.Presentation do
  @moduledoc "Maintain short-lived sidebar tokens and optional pane labels."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Mirror, Socket}
  alias Jarvis2.MCP.Identity

  @ttl_ms 60_000
  @max_pending 256
  @batch_size 8

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    for topic <-
          ~w(herdr:pane.agent_status_changed herdr:pane.agent_detected mcp:tool_call mcp:status_reported mirror:updated),
        do: Jarvis2.Bus.subscribe(topic)

    {:ok,
     %{
       mirror: Keyword.get(opts, :mirror, Application.get_env(:jarvis2, :mirror, Mirror)),
       socket: Keyword.get(opts, :socket, Application.get_env(:jarvis2, :herdr_socket, Socket)),
       debounce_ms: Keyword.get(opts, :debounce_ms, 200),
       pending: %{},
       timer: nil
     }}
  end

  @impl true
  def handle_info({:jarvis2, "herdr:pane.agent_status_changed", %{data: data}}, state)
      when is_map(data) do
    pane = data["pane_id"]
    workspace = data["workspace_id"]
    status = data["agent_status"]

    if valid_id?(pane) and valid_id?(workspace) and
         status in ~w(idle working blocked done unknown) do
      {:noreply,
       enqueue(state, {:status, pane}, %{
         pane: pane,
         workspace: workspace,
         status: status,
         agent: data["agent"]
       })}
    else
      {:noreply, state}
    end
  end

  def handle_info({:jarvis2, "mcp:tool_call", %{caller: caller, tool: tool}}, state)
      when is_map(caller) and is_binary(tool) do
    if valid_id?(caller[:pane]) and valid_id?(caller[:workspace]) and
         Regex.match?(~r/\A[a-z_]{1,40}\z/, tool) do
      entry = %{pane: caller.pane, workspace: caller.workspace, tool: tool}
      {:noreply, enqueue(state, {:tool, caller.workspace}, entry)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:jarvis2, "mcp:status_reported", %{caller: caller, summary: summary}}, state)
      when is_map(caller) and is_binary(summary) and byte_size(summary) <= 256 do
    if valid_id?(caller[:pane]) and valid_id?(caller[:workspace]) and
         valid_kind?(caller[:agent_kind]) do
      entry = %{
        pane: caller.pane,
        workspace: caller.workspace,
        kind: caller.agent_kind,
        name: caller[:agent_name],
        summary: summary
      }

      {:noreply, enqueue(state, {:hygiene, caller.pane}, entry)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:jarvis2, "herdr:pane.agent_detected", %{data: data}}, state)
      when is_map(data) do
    pane = data["pane_id"]
    workspace = data["workspace_id"]
    kind = data["agent"]

    if valid_id?(pane) and valid_id?(workspace) and valid_kind?(kind) and data["released"] != true do
      key = {:hygiene, pane}
      entry = %{pane: pane, workspace: workspace, kind: kind, name: nil, summary: nil}
      # Preserve an already-queued task summary for the same agent.
      state =
        if match?(
             %{kind: ^kind, workspace: ^workspace, summary: summary} when is_binary(summary),
             state.pending[key]
           ),
           do: state,
           else: enqueue(state, key, entry)

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:jarvis2, "mirror:updated", %{source: source, view: %{stale: false}}}, state) do
    if source == GenServer.whereis(state.mirror),
      do: {:noreply, schedule(state)},
      else: {:noreply, state}
  end

  def handle_info(:flush, state) do
    state = %{state | timer: nil, pending: unexpired(state.pending)}

    case Mirror.get(state.mirror) do
      %{stale: false, snapshot: snapshot} = view when is_map(snapshot) ->
        batch = Enum.take(state.pending, @batch_size)
        for {key, entry} <- batch, do: present(key, entry, view, state.socket)
        pending = Map.drop(state.pending, Enum.map(batch, &elem(&1, 0)))

        {:noreply,
         if(map_size(pending) > 0,
           do: schedule(%{state | pending: pending}),
           else: %{state | pending: pending}
         )}

      _ ->
        # Reconciliation emits mirror:updated; do not retry an uncertain write.
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp enqueue(state, key, entry) do
    pending = unexpired(state.pending)

    if Map.has_key?(pending, key) or map_size(pending) < @max_pending do
      entry = Map.put(entry, :queued_at, System.monotonic_time(:millisecond))
      schedule(%{state | pending: Map.put(pending, key, entry)})
    else
      Logger.warning("Herdr presentation queue full; update dropped")
      %{state | pending: pending}
    end
  end

  defp schedule(%{timer: nil, pending: pending} = state) when map_size(pending) > 0,
    do: %{state | timer: Process.send_after(self(), :flush, state.debounce_ms)}

  defp schedule(state), do: state

  defp unexpired(pending) do
    now = System.monotonic_time(:millisecond)
    Map.filter(pending, fn {_key, entry} -> now - entry.queued_at < @ttl_ms end)
  end

  defp present({:tool, _}, entry, view, socket) do
    if resolve(entry, view).pane != "unknown" do
      params = %{
        workspace_id: entry.workspace,
        source: "custom:jarvis2-mcp",
        tokens: %{last_tool: entry.tool},
        ttl_ms: @ttl_ms
      }

      expires_at = System.system_time(:millisecond) + @ttl_ms

      if write(:sidebar_tokens, "workspace.report_metadata", params, entry.pane, socket) == :ok do
        Jarvis2.Scenarios.Restore.record_token(
          "workspace.report_metadata",
          params,
          entry.pane,
          view,
          expires_at
        )
      end
    end
  end

  defp present({:status, _}, entry, view, socket) do
    agent = find_agent(view, entry.pane)

    if resolve(entry, view).pane != "unknown" and is_map(agent) and
         agent["agent_status"] == entry.status and
         (not is_binary(entry.agent) or agent["agent"] == entry.agent) do
      params = %{
        pane_id: entry.pane,
        source: "custom:jarvis2-state",
        tokens: %{agent_state: entry.status},
        ttl_ms: @ttl_ms
      }

      expires_at = System.system_time(:millisecond) + @ttl_ms

      if write(:sidebar_tokens, "pane.report_metadata", params, entry.pane, socket) == :ok do
        Jarvis2.Scenarios.Restore.record_token(
          "pane.report_metadata",
          params,
          entry.pane,
          view,
          expires_at
        )
      end
    end
  end

  defp present({:hygiene, _}, entry, view, socket) do
    caller = resolve(entry, view)
    agent = find_agent(view, entry.pane)

    if caller.pane != "unknown" and is_map(agent) and agent["agent"] == entry.kind and
         (is_nil(entry.name) or agent["name"] == entry.name) do
      pane = Enum.find(view.snapshot["panes"], &(&1["pane_id"] == entry.pane))
      kind = clean(entry.kind, 32)
      summary = clean(entry.summary, 64)
      label = if summary == "", do: kind, else: kind <> ": " <> summary

      if label != "" and pane["label"] != label do
        write(
          :pane_hygiene,
          "pane.rename",
          %{pane_id: entry.pane, label: label},
          entry.pane,
          socket
        )
      end

      rename_tab(view, pane, entry.pane, socket)
    end
  end

  defp rename_tab(view, pane, caller, socket) do
    workspace =
      Enum.find(view.snapshot["workspaces"], &(&1["workspace_id"] == pane["workspace_id"])) || %{}

    tab =
      Enum.find(
        view.snapshot["tabs"],
        &(&1["tab_id"] == pane["tab_id"] and &1["workspace_id"] == pane["workspace_id"])
      )

    tree = workspace["worktree"]

    if is_map(tree) and is_map(tab) and not Map.has_key?(view.worktree_errors, tree["repo_key"]) do
      worktrees = Map.get(view.worktrees, tree["repo_key"], [])
      current = Enum.find(worktrees, &(is_map(&1) and &1["path"] == tree["checkout_path"])) || %{}
      branch = clean(current["branch"], 80)

      if branch != "" and tab["label"] != branch do
        write(
          :pane_hygiene,
          "tab.rename",
          %{tab_id: tab["tab_id"], label: branch},
          caller,
          socket
        )
      end
    end
  end

  defp resolve(entry, view),
    do:
      Identity.resolve(
        %{"x-herdr-pane" => entry.pane, "x-herdr-workspace" => entry.workspace},
        view
      )

  defp find_agent(view, pane), do: Enum.find(view.snapshot["agents"], &(&1["pane_id"] == pane))

  defp clean(value, limit) when is_binary(value),
    do: value |> String.replace(~r/[\p{C}\s]+/u, " ") |> String.trim() |> String.slice(0, limit)

  defp clean(_, _), do: ""

  defp valid_id?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and value != "unknown"

  defp valid_kind?(value), do: is_binary(value) and byte_size(value) in 1..64

  defp write(scenario, method, params, caller, socket) do
    case Actions.call(scenario, method, params, caller: caller, server: socket, timeout: 1_000) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Logger.warning("Herdr presentation update failed method=#{inspect(method)}")
        :error
    end
  end
end
