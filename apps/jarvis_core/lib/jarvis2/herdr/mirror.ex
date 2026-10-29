defmodule Jarvis2.Herdr.Mirror do
  @moduledoc "An authoritative, invalidation-driven cache of the current Herdr session."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Client, LayoutDiff}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def get(server \\ __MODULE__), do: GenServer.call(server, :get)

  def online(server \\ __MODULE__, ready_panes \\ []),
    do: GenServer.cast(server, {:online, ready_panes})

  def offline(server \\ __MODULE__), do: GenServer.cast(server, :offline)
  def invalidate(server \\ __MODULE__), do: GenServer.cast(server, :invalidate)

  @impl true
  def init(opts) do
    {:ok,
     %{
       socket: Keyword.get(opts, :socket, Jarvis2.Herdr.Socket),
       tasks: Keyword.get(opts, :task_supervisor, Jarvis2.TaskSupervisor),
       retry_ms: Keyword.get(opts, :retry_ms, 500),
       attempts: 0,
       online: false,
       ready_panes: MapSet.new(),
       epoch: 0,
       dirty: false,
       timer: nil,
       task: nil,
       snapshot: nil,
       worktrees: %{},
       errors: %{},
       layout_baseline: nil,
       layout_diff: nil,
       diff_sequence: 0,
       diff_gap: true,
       stale: true
     }}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, view(state), state}

  @impl true
  def handle_cast({:online, ready_panes}, state) do
    {:noreply,
     state
     |> Map.put(:online, true)
     |> Map.put(:ready_panes, MapSet.new(ready_panes))
     |> mark_dirty()}
  end

  def handle_cast(:offline, state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    {:noreply,
     %{
       state
       | online: false,
         stale: true,
         dirty: true,
         epoch: state.epoch + 1,
         timer: nil,
         diff_gap: true
     }}
  end

  def handle_cast(:invalidate, state), do: {:noreply, mark_dirty(state)}

  @impl true
  def handle_info(:refresh, state) do
    state = %{state | timer: nil}

    if state.online and state.dirty and is_nil(state.task) do
      task = Task.Supervisor.async_nolink(state.tasks, fn -> load(state.socket) end)
      {:noreply, %{state | task: {task, state.epoch}, dirty: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{task: {%Task{ref: ref}, epoch}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    state =
      cond do
        epoch != state.epoch or not state.online ->
          state

        match?({:ok, _, _, _}, result) ->
          {:ok, snapshot, worktrees, errors} = result
          old = state.snapshot

          state = %{
            state
            | snapshot: snapshot,
              worktrees: merge_worktrees(state.worktrees, worktrees, errors),
              errors: errors,
              stale: state.dirty or not agents_subscribed?(snapshot, state.ready_panes)
          }

          log_snapshot(old, snapshot)
          state = update_layout_diff(state)
          Jarvis2.Bus.publish("mirror:updated", %{source: self(), view: view(state)})

          if Enum.any?(errors, fn {_repo, code} -> code == "worktree_busy" end),
            do: retry(%{state | dirty: true}),
            else: %{state | attempts: 0}

        true ->
          Logger.warning("Herdr snapshot refresh failed")
          retry(%{state | dirty: true, stale: true, diff_gap: true})
      end

    {:noreply, if(state.online and state.dirty, do: schedule(state, 20), else: state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: {%Task{ref: ref}, _}} = state) do
    Logger.warning("Herdr snapshot refresh task failed")
    {:noreply, retry(%{state | task: nil, dirty: true, stale: true, diff_gap: true})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp mark_dirty(state), do: schedule(%{state | dirty: true, stale: true}, 20)

  defp retry(state) do
    base = min(state.retry_ms * Integer.pow(2, min(state.attempts, 5)), 10_000)
    delay = base + :rand.uniform(max(div(base, 5), 1)) - 1
    schedule(%{state | attempts: state.attempts + 1}, delay)
  end

  defp schedule(%{timer: nil, online: true} = state, delay),
    do: %{state | timer: Process.send_after(self(), :refresh, delay)}

  defp schedule(state, _delay), do: state

  defp view(state),
    do: %{
      snapshot: state.snapshot,
      worktrees: state.worktrees,
      worktree_errors: state.errors,
      layout_diff: state.layout_diff,
      stale: state.stale
    }

  defp update_layout_diff(%{stale: true} = state), do: state

  defp update_layout_diff(state) do
    case LayoutDiff.project(state.snapshot, state.worktrees, state.errors) do
      {:ok, current} ->
        {status, changes, truncated} =
          if state.layout_baseline do
            {changes, truncated} = LayoutDiff.between(state.layout_baseline, current)
            status = if state.diff_gap, do: "resynced", else: "changed"
            {status, changes, truncated}
          else
            {"baseline", [], false}
          end

        state = %{state | layout_baseline: current, diff_gap: false}

        if status != "changed" or changes != [] or truncated,
          do: publish_layout_diff(state, status, changes, truncated),
          else: state

      {:error, _} ->
        state = %{state | diff_gap: true}

        if match?(%{status: "unavailable"}, state.layout_diff),
          do: state,
          else: publish_layout_diff(state, "unavailable", [], false)
    end
  end

  defp publish_layout_diff(state, status, changes, truncated) do
    diff = %{
      sequence: state.diff_sequence + 1,
      status: status,
      changes: changes,
      truncated: truncated
    }

    Logger.info(
      "Herdr layout diff status=#{status} changes=#{length(changes)} truncated=#{truncated}"
    )

    Jarvis2.Bus.publish("mirror:layout_diff", %{source: self(), diff: diff})
    %{state | diff_sequence: diff.sequence, layout_diff: diff}
  end

  defp agents_subscribed?(snapshot, ready_panes) do
    required = snapshot["agents"] |> Enum.map(& &1["pane_id"]) |> MapSet.new()
    MapSet.subset?(required, ready_panes)
  end

  defp load(socket) do
    case Client.snapshot(server: socket) do
      {:ok, %{"snapshot" => snapshot}} when is_map(snapshot) ->
        if Enum.all?(~w(workspaces tabs panes layouts agents), fn key ->
             is_list(snapshot[key]) and Enum.all?(snapshot[key], &is_map/1)
           end) and Enum.all?(snapshot["agents"], &is_binary(&1["pane_id"])) do
          {trees, errors} = load_worktrees(snapshot["workspaces"], socket)
          {:ok, snapshot, trees, errors}
        else
          {:error, :invalid_snapshot}
        end

      _ ->
        {:error, :snapshot_unavailable}
    end
  end

  defp load_worktrees(workspaces, socket) do
    workspaces
    |> Enum.reduce(%{}, fn
      %{"workspace_id" => id, "worktree" => %{"repo_key" => key}}, repos
      when is_binary(id) and is_binary(key) ->
        Map.put_new(repos, key, id)

      _, repos ->
        repos
    end)
    |> Enum.reduce({%{}, %{}}, fn {key, workspace}, {trees, errors} ->
      case Client.list_worktrees(workspace, server: socket) do
        {:ok, %{"worktrees" => list}} when is_list(list) -> {Map.put(trees, key, list), errors}
        {:error, %{code: code}} -> {trees, Map.put(errors, key, code)}
        _ -> {trees, Map.put(errors, key, "invalid_response")}
      end
    end)
  end

  defp merge_worktrees(old, current, errors) do
    retained = Map.take(old, Map.keys(errors))
    Map.merge(retained, current)
  end

  defp log_snapshot(old, snapshot) do
    counts = fn value -> Enum.map(~w(workspaces tabs panes agents), &{&1, length(value[&1])}) end
    current = counts.(snapshot)
    previous = if old, do: counts.(old), else: []

    if previous != current,
      do: Logger.info("Herdr snapshot counts=#{inspect(current)} previous=#{inspect(previous)}")
  end
end
