defmodule Jarvis2.Runs do
  @moduledoc """
  Agent jobs started from the UI. A run is created in the database first; the Herdr side effects
  then happen through `Jarvis2.Runs.Launcher`, and the monitor keeps the status in step with what
  Herdr reports. Changes are broadcast on `"runs"` and `"run:<id>"`.
  """
  import Ecto.Query

  alias Jarvis2.{Journal, Questions, Repo, Tokens}
  alias Jarvis2.MCP.MixRunner
  alias Jarvis2.Runs.{Launcher, Run}

  @topic "runs"
  @stale_start_ms 120_000

  def topic, do: @topic

  def defaults do
    settings = Jarvis2.Settings.get()

    %{
      kind: settings.default_kind,
      model: settings.default_model,
      thinking: settings.default_thinking
    }
  end

  def change_run(run \\ %Run{}, attrs \\ %{}), do: Run.changeset(run, attrs)

  def get_run(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id), %Run{} = run <- Repo.get(Run, uuid), do: run
  end

  def list_runs(opts \\ []) do
    Run
    |> then(fn q ->
      case Keyword.get(opts, :status) do
        nil -> q
        status -> where(q, [r], r.status == ^status)
      end
    end)
    |> order_by(desc: :inserted_at)
    |> limit(^Keyword.get(opts, :limit, 200))
    |> Repo.all()
  end

  def active_runs,
    do: Repo.all(from(r in Run, where: r.status in [:starting, :working, :blocked, :done]))

  @doc "Creates the run row only; nothing is sent to Herdr."
  def create_run(attrs) do
    case Repo.insert(Run.changeset(%Run{}, with_defaults(attrs))) do
      {:ok, run} ->
        record(run, "run.created", %{kind: run.kind, model: run.model, thinking: run.thinking})
        broadcast(run)
        {:ok, run}

      error ->
        error
    end
  end

  @doc "Creates a run and launches it in the background."
  def start_run(attrs) do
    with {:ok, run} <- create_run(attrs) do
      {:ok, _} = Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn -> launch(run) end)
      {:ok, run}
    end
  end

  @doc "Runs the launch sequence for a `:starting` run and records the outcome."
  def launch(%Run{status: :starting} = run) do
    case Launcher.start(run) do
      {:ok, %{mode: :dry, plan: plan}} ->
        run
        |> progress(%{status: :dry_run, started_at: now()})
        |> record("run.start", %{mode: "dry", planned: plan}, :dry_run)

      {:ok, %{mode: :live} = info} ->
        run
        |> progress(%{
          status: :working,
          pane_id: info.pane_id,
          terminal_id: info.terminal_id,
          agent_name: info.agent_name,
          started_at: now()
        })
        |> record(
          "run.start",
          %{mode: "live", pane: info.pane_id, prompt: info.prompt},
          if(info.prompt == "submitted", do: :ok, else: :error)
        )

      {:error, message} ->
        run
        |> progress(%{status: :failed, finished_at: now(), result: %{error: message}})
        |> record("run.start", %{error: message}, :error)
    end
  end

  def launch(run), do: run

  @doc """
  Runs an allow-listed Mix task as a run of kind `mix` and returns the runner's own result. The
  run records the exit status and bounded output, and `parent_run_id` links it to the agent run
  that asked for it.
  """
  def run_mix(task, project, opts \\ []) do
    attrs = %{task: task, cwd: MixRunner.project_root(), parent_run_id: opts[:parent_run_id]}

    case %Run{} |> Run.mix_changeset(attrs) |> Repo.insert() do
      {:ok, run} ->
        record(run, "run.created", %{kind: "mix", task: task}, :ok, :ui)
        broadcast(run)
        result = MixRunner.run(task, project)
        finish_mix(run, result)
        result

      {:error, _changeset} ->
        {:error, "Mix task is not allowed"}
    end
  end

  @doc "Starts a Mix run in the background (from the UI)."
  def start_mix(task) do
    if task in MixRunner.tasks() do
      {:ok, _} = Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn -> run_mix(task, nil) end)
      :ok
    else
      {:error, "Mix task is not allowed"}
    end
  end

  defp finish_mix(run, {:ok, %{exit_status: status} = result}) do
    run
    |> progress(%{
      status: if(status == 0, do: :done, else: :failed),
      finished_at: now(),
      result: Map.take(result, [:exit_status, :output, :truncated, :timed_out])
    })
    |> record(
      "run.mix",
      %{exit_status: status, timed_out: result.timed_out},
      if(status == 0, do: :ok, else: :error)
    )
  end

  defp finish_mix(run, {:error, message}) do
    run
    |> progress(%{status: :failed, finished_at: now(), result: %{error: message}})
    |> record("run.mix", %{error: message}, :error)
  end

  @doc "Closes the run's pane (when it is still ours) and marks the run stopped."
  def stop_run(%Run{kind: "mix"}), do: {:error, "Mix runs finish on their own."}

  def stop_run(%Run{} = run) do
    if Run.active?(run) or run.status == :dry_run do
      run |> Launcher.close() |> finish_stop(run)
    else
      {:error, "The run is not active."}
    end
  end

  defp finish_stop({:ok, how}, run) do
    run
    |> progress(%{status: :stopped, finished_at: now()})
    |> record("run.stop", %{pane: how}, if(how == :dry_run, do: :dry_run, else: :ok))
    |> then(&{:ok, &1})
  end

  defp finish_stop({:error, message}, run) do
    record(run, "run.stop", %{error: message}, :error)
    {:error, message}
  end

  def focus_run(%Run{} = run), do: Launcher.focus(run)

  @doc "An agent's own report (via MCP) of how it is doing."
  def report_status(run_id, state, summary) when state in ["working", "blocked", "done"] do
    with %Run{} = run <- get_run(run_id), true <- Run.active?(run) do
      updated = progress(run, %{status: String.to_existing_atom(state)})

      # The summary is kept (bounded) because the user started this run and wants to read it.
      Journal.record(%{
        source: :mcp,
        type: "run.report",
        run_id: run.id,
        payload: %{state: state, status_summary: summary}
      })

      {:ok, updated}
    else
      _ -> {:error, "The run is not active."}
    end
  end

  def report_status(_run_id, _state, _summary),
    do: {:error, "state must be working, blocked or done"}

  @doc "An agent's final result (via MCP): finishes the run and closes its credentials."
  def submit_result(run_id, summary, artifacts) do
    with %Run{} = run <- get_run(run_id), true <- Run.active?(run) do
      updated =
        progress(run, %{
          status: :done,
          finished_at: now(),
          result: %{summary: summary, artifacts: artifacts}
        })

      Tokens.revoke_for_run(run.id)
      Questions.cancel_for_run(run.id)
      record(updated, "run.result", %{artifacts: length(artifacts)})
      {:ok, updated}
    else
      _ -> {:error, "The run is not active."}
    end
  end

  def prompt_run(%Run{} = run, text) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" -> {:error, "Write something to send."}
      byte_size(text) > 6_000 -> {:error, "The prompt is too long."}
      not Run.active?(run) -> {:error, "The run is not active."}
      true -> Launcher.prompt(run, text)
    end
  end

  @doc """
  Brings active runs in line with a fresh mirror view and returns the updated `seen` map of last
  observed agent statuses. A run is `done` when its agent goes from working or blocked to idle.
  """
  def apply_view(%{stale: false, snapshot: snapshot} = view, seen) when is_map(snapshot) do
    Enum.reduce(active_runs(), seen, fn run, seen -> reconcile(run, view, seen) end)
  end

  def apply_view(_view, seen), do: seen

  defp reconcile(%Run{pane_id: nil, status: :starting} = run, _view, seen) do
    if DateTime.diff(now(), run.inserted_at, :millisecond) > @stale_start_ms do
      run
      |> progress(%{status: :failed, finished_at: now(), result: %{error: "launch interrupted"}})
      |> record("run.status", %{to: "failed", reason: "launch interrupted"}, :error)
    end

    seen
  end

  # A Mix job whose server died mid-run never reports back.
  defp reconcile(%Run{pane_id: nil, kind: "mix", status: :working} = run, _view, seen) do
    if DateTime.diff(now(), run.inserted_at, :millisecond) > @stale_start_ms * 2 do
      run
      |> progress(%{status: :failed, finished_at: now(), result: %{error: "interrupted"}})
      |> record("run.status", %{to: "failed", reason: "interrupted"}, :error)
    end

    seen
  end

  defp reconcile(%Run{pane_id: nil}, _view, seen), do: seen

  defp reconcile(run, view, seen) do
    case Launcher.find(run, view) do
      nil ->
        run
        |> progress(%{status: :lost, finished_at: now()})
        |> record("run.status", %{to: "lost"}, :error)

        Map.delete(seen, run.id)

      {_pane, nil} ->
        seen

      {_pane, agent} ->
        current = agent["agent_status"]
        target = next_status(run.status, Map.get(seen, run.id), current)

        if target != run.status do
          run
          |> progress(%{status: target})
          |> record("run.status", %{from: run.status, to: target})
        end

        Map.put(seen, run.id, current)
    end
  end

  defp next_status(_status, _prev, "working"), do: :working
  defp next_status(_status, _prev, "blocked"), do: :blocked

  defp next_status(_status, prev, idle)
       when idle in ["idle", "done"] and prev in ["working", "blocked"], do: :done

  defp next_status(status, _prev, _current), do: status

  defp progress(run, attrs) do
    # Round-trip the result so the returned run matches what a reload would give.
    attrs = Map.update(attrs, :result, nil, &(&1 && &1 |> Jason.encode!() |> Jason.decode!()))
    attrs = if attrs.result, do: attrs, else: Map.delete(attrs, :result)

    {:ok, run} = run |> Run.progress_changeset(attrs) |> Repo.update()

    # A run that can no longer act must not keep credentials or open questions.
    if run.status in [:failed, :lost, :stopped] do
      Tokens.revoke_for_run(run.id)
      Questions.cancel_for_run(run.id)
    end

    broadcast(run)
    run
  end

  defp record(run, type, payload, outcome \\ :ok, source \\ :ui) do
    Journal.record(%{
      source: source,
      type: type,
      run_id: run.id,
      outcome: outcome,
      payload: payload
    })

    run
  end

  defp broadcast(run) do
    Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, @topic, {:run, run})
    Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, "run:" <> run.id, {:run, run})
  end

  defp with_defaults(attrs) do
    defaults = Map.new(defaults(), fn {key, value} -> {to_string(key), value} end)
    Map.merge(defaults, Map.new(attrs, fn {key, value} -> {to_string(key), value} end))
  end

  defp now, do: DateTime.utc_now()
end
