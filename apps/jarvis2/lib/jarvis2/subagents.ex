defmodule Jarvis2.Subagents do
  @moduledoc "Bounded, owned review runs spawned by an agent."
  import Ecto.Query
  alias Jarvis2.{Fleet, Kanban, Repo, Roles, Runs}
  alias Jarvis2.Herdr.{Actions, Mirror}
  alias Jarvis2.Runs.{Launcher, Run}
  alias Jarvis2.Subagents.Prompt

  @max_spawns 3
  @max_task 32_768
  @live [:starting, :working, :blocked, :done]

  def spawn(run_id, role_name, task) do
    if :subagents in Application.get_env(:jarvis2, :live_scenarios, []) do
      synchronize(run_id, fn -> spawn_locked(run_id, role_name, task) end)
    else
      {:error, "subagents are disabled"}
    end
  end

  defp spawn_locked(run_id, role_name, task) do
    with %Run{kind: "pi", spawned_by_run_id: nil} = parent <- Runs.get_run(run_id),
         true <- spawner_active?(parent),
         true <- anchor_available?(parent),
         {:ok, role} <- subagent_role(role_name),
         true <- valid_task?(task),
         :ok <- limits(parent.id),
         prompt = Prompt.build(role, task),
         true <- Actions.valid_prompt_text?(prompt),
         {:ok, child} <- create(parent, role, prompt) do
      case Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn -> launch(child.id) end) do
        {:ok, _pid} ->
          {:ok, %{id: child.id, role: child.role, status: "starting"}}

        {:error, _} ->
          Runs.fail_subagent(child, "could not start launcher")
          {:error, "could not start subagent"}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "invalid spawner or task"}
    end
  end

  defp spawner_active?(parent) do
    card = Kanban.get_card_by_run(parent.id)

    Run.active?(parent) and is_nil(parent.result) and
      (is_nil(card) or card.column not in [:done, :archive])
  end

  defp anchor_available?(%Run{pane_id: pane, tab_id: tab, terminal_id: terminal} = parent)
       when is_binary(pane) and is_binary(tab) and is_binary(terminal) and terminal != "" do
    view = Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))

    match?(%{stale: false}, view) and
      match?({%{"tab_id" => ^tab}, %{"agent" => "pi"}}, Launcher.find(parent, view))
  catch
    :exit, _ -> false
  end

  defp anchor_available?(_), do: false

  defp subagent_role(name) do
    case Roles.get(name) do
      {:ok, %{subagent: true} = role} ->
        {:ok, role}

      _ ->
        available = for {:ok, %{subagent: true, name: name}} <- Roles.list(), do: name
        {:error, "role #{name} is not a subagent role; available: #{Enum.join(available, ", ")}"}
    end
  end

  defp valid_task?(task),
    do:
      is_binary(task) and byte_size(task) in 1..@max_task and
        Actions.valid_prompt_characters?(task) and String.trim(task) != ""

  defp limits(id) do
    children = Repo.all(from r in Run, where: r.spawned_by_run_id == ^id)

    cond do
      Enum.any?(children, &(&1.status in @live)) or failed_still_working?(children) ->
        {:error, "a subagent is already running"}

      length(children) >= @max_spawns ->
        {:error, "subagent limit reached"}

      true ->
        :ok
    end
  end

  # An acknowledged Escape does not mean Pi has finished interrupting its turn.
  defp failed_still_working?(children) do
    failed = Enum.filter(children, &(&1.status == :failed and is_binary(&1.pane_id)))

    if failed == [], do: false, else: failed_panes_busy?(failed)
  end

  defp failed_panes_busy?(failed) do
    case Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror)) do
      %{stale: false} = view -> Enum.any?(failed, &busy_pane?(&1, view))
      _ -> true
    end
  catch
    :exit, _ -> true
  end

  defp busy_pane?(child, view) do
    case Launcher.find(child, view) do
      {_, %{"agent_status" => status}} -> status not in ["idle", "done"]
      _ -> false
    end
  end

  defp create(parent, role, prompt) do
    Runs.create_run(%{
      name: role.name,
      role: role.name,
      kind: "pi",
      model: role.model,
      thinking: role.effort,
      cwd: parent.cwd,
      worktree: parent.worktree,
      task: prompt,
      spawned_by_run_id: parent.id,
      session_id: Ecto.UUID.generate()
    })
  end

  defp launch(id) do
    child = Runs.get_run(id)

    synchronize(child.spawned_by_run_id, fn -> launch_locked(Runs.get_run(id)) end)
  end

  defp launch_locked(child) do
    parent = Runs.get_run(child.spawned_by_run_id)

    cond do
      parent && spawner_active?(parent) && child.status == :starting && anchor_available?(parent) ->
        Runs.launch(child, fn _ -> :ok end, child.role, {:split, parent.pane_id, parent.tab_id})

      child.status == :starting ->
        Runs.fail_subagent(child, "spawner is no longer available")

      true ->
        :ok
    end
  end

  def wait(id, run_id, timeout_ms)
      when is_binary(id) and is_integer(timeout_ms) and timeout_ms >= 0 do
    topic = "run:" <> id
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, topic)

    try do
      wait_until(id, run_id, System.monotonic_time(:millisecond) + timeout_ms)
    after
      Phoenix.PubSub.unsubscribe(Jarvis2.PubSub, topic)
    end
  end

  def wait(_, _, _), do: {:error, "no such subagent"}

  defp wait_until(id, owner, deadline) do
    case Runs.get_run(id) do
      %Run{spawned_by_run_id: ^owner} = run when not is_nil(owner) ->
        status = status(run)
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        if status in ["starting", "working", "blocked"] and remaining > 0 do
          receive do
            {:run, %Run{id: ^id}} -> wait_until(id, owner, deadline)
          after
            remaining -> wait_until(id, owner, deadline)
          end
        else
          result = %{id: id, status: status}

          {:ok,
           if(status == "finished",
             do: Map.put(result, :result, Prompt.result(run)),
             else: result
           )}
        end

      _ ->
        {:error, "no such subagent"}
    end
  end

  defp status(%Run{status: status}) when status in [:failed, :stopped, :lost],
    do: Atom.to_string(status)

  defp status(%Run{status: :finished, result: %{"summary" => _}}), do: "finished"
  defp status(%Run{status: :done}), do: "working"
  defp status(%Run{status: status}), do: Atom.to_string(status)

  @doc false
  def pane?(pane) do
    case Runs.get_active_by_pane(pane) do
      %Run{spawned_by_run_id: id} when is_binary(id) -> true
      _ -> false
    end
  end

  @doc false
  def synchronize(id, fun), do: :global.trans({{__MODULE__, id}, self()}, fun)

  @doc "Stop all children of a spawner, including failed children left for inspection."
  def stop_all(id) when is_binary(id) do
    synchronize(id, fn ->
      children(id) |> Enum.each(&stop_child/1)
    end)
  end

  defp children(id) do
    Repo.all(
      from r in Run,
        where:
          r.spawned_by_run_id == ^id and
            r.status in [:starting, :working, :blocked, :done, :failed]
    )
  end

  defp stop_child(run) do
    case close(run) do
      {:ok, _} -> Runs.transition_subagent(run, :stopped, "spawner ended")
      {:error, _} -> :ok
    end
  end

  @doc false
  def tick(view, seen) do
    runs =
      Repo.all(
        from r in Run,
          where:
            not is_nil(r.spawned_by_run_id) and
              r.status in [:starting, :working, :blocked, :done, :failed]
      )

    Enum.reduce(runs, seen, fn run, seen ->
      synchronize(run.spawned_by_run_id, fn -> tick_run(Runs.get_run(run.id), view, seen) end)
    end)
  end

  defp tick_run(nil, _view, seen), do: seen

  defp tick_run(%Run{status: status}, _view, seen) when status in [:finished, :stopped, :lost],
    do: seen

  defp tick_run(run, view, seen) do
    parent = Runs.get_run(run.spawned_by_run_id)

    cond do
      is_nil(parent) or not spawner_active?(parent) ->
        stop_child(run)
        Map.delete(seen, run.id)

      run.status == :failed ->
        seen

      run.status == :starting and elapsed?(run.inserted_at, 120) ->
        Runs.fail_subagent(run, "launch interrupted")
        seen

      is_nil(run.pane_id) ->
        seen

      true ->
        observe(run, view, seen)
    end
  end

  defp observe(run, view, seen) do
    case Launcher.find(run, view) do
      nil ->
        observe_missing(run, seen)

      {_pane, agent} ->
        current = if agent, do: agent["agent_status"]
        previous = Map.get(seen, run.id)
        idle = current in ["idle", "done"] and previous in ["working", "blocked"]
        reconcile_agent(run, current, idle)
        if current, do: Map.put(seen, run.id, current), else: seen
    end
  end

  defp observe_missing(run, seen) do
    cond do
      has_report?(run) ->
        Runs.transition_subagent(run, :finished, "pane gone")
        Map.delete(seen, run.id)

      Map.has_key?(seen, run.id) or elapsed?(run.started_at, 5) ->
        Runs.transition_subagent(run, :lost, "pane gone")
        Map.delete(seen, run.id)

      true ->
        seen
    end
  end

  defp reconcile_agent(%Run{result: %{"summary" => summary}} = run, _current, idle)
       when is_binary(summary) do
    if idle or elapsed?(run.finished_at, 20) do
      case close(run) do
        {:ok, _} -> Runs.transition_subagent(run, :finished, "reported")
        {:error, _} -> :ok
      end
    end
  end

  defp reconcile_agent(run, current, idle) do
    cond do
      elapsed?(run.started_at, 600) ->
        interrupt(run)

      idle ->
        Runs.transition_subagent(run, :failed, "idle without a result")

      current in ["working", "blocked"] ->
        status = String.to_existing_atom(current)
        if run.status != status, do: Runs.transition_subagent(run, status)

      true ->
        :ok
    end
  end

  defp has_report?(%Run{result: %{"summary" => summary}}) when is_binary(summary), do: true
  defp has_report?(_), do: false
  defp elapsed?(nil, _), do: false
  defp elapsed?(time, seconds), do: DateTime.diff(DateTime.utc_now(), time, :second) >= seconds

  defp interrupt(run) do
    result = Launcher.interrupt_pane(run)

    Fleet.audit(result, "fleet.interrupt_subagent", Launcher.caller(run), %{pane: run.pane_id},
      source: :ui
    )

    if match?({:ok, _}, result), do: Runs.transition_subagent(run, :failed, "deadline exceeded")
  end

  defp close(run) do
    result = Launcher.close_pane(run)

    Fleet.audit(result, "fleet.close_subagent", Launcher.caller(run), %{pane: run.pane_id},
      source: :ui
    )
  end
end
