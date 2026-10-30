defmodule Jarvis2.Runs do
  @moduledoc """
  Agent jobs started from the UI. A run is created in the database first; the Herdr side effects
  then happen through `Jarvis2.Runs.Launcher`, and the monitor keeps the status in step with what
  Herdr reports. Changes are broadcast on `"runs"` and `"run:<id>"`.
  """
  import Ecto.Query

  alias Jarvis2.{Journal, Questions, Repo}
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

  def get_run(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id), %Run{} = run <- Repo.get(Run, uuid), do: run
  end

  def active_runs,
    do: Repo.all(from(r in Run, where: r.status in [:starting, :working, :blocked, :done]))

  @doc "Find the most recent active run for a pane."
  def get_active_by_pane(pane) when is_binary(pane) and pane != "" do
    Repo.one(
      from(r in Run,
        where: r.pane_id == ^pane and r.status in [:starting, :working, :blocked, :done],
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1
      )
    )
  end

  def get_active_by_pane(_), do: nil

  @doc "Creates the run row only; nothing is sent to Herdr."
  def create_run(attrs) do
    case Repo.insert(Run.changeset(%Run{}, with_defaults(attrs))) do
      {:ok, run} ->
        record(run, "run.created", %{
          kind: run.kind,
          model: run.model,
          thinking: run.thinking,
          role: run.role
        })

        broadcast(run)
        {:ok, run}

      error ->
        error
    end
  end

  @doc "Runs the launch sequence for a `:starting` run and records the outcome."
  def launch(run, on_prompt \\ fn _ -> :ok end, label \\ nil, placement \\ :tab)

  def launch(%Run{status: :starting} = run, on_prompt, label, placement) do
    on_started = fn {stage, info} -> record_launch_pane(run, stage, info) end

    case Launcher.start(run, label, placement, on_started) do
      {:ok, info} ->
        current = get_run(run.id)
        status = if current.result, do: current.status, else: :working

        launched =
          current
          |> progress(%{
            status: status,
            workspace_id: info.workspace_id,
            cwd: info.cwd,
            tab_id: info.tab_id,
            pane_id: info.pane_id,
            terminal_id: info.terminal_id,
            agent_name: info.agent_name,
            started_at: current.started_at || now()
          })
          |> record(
            "run.start",
            %{pane: info.pane_id, prompt: info.prompt},
            if(info.prompt == "submitted", do: :ok, else: :error)
          )

        on_prompt.(info.prompt)
        launched

      {:error, message} ->
        get_run(run.id)
        |> progress(%{status: :failed, finished_at: now(), result: %{error: message}})
        |> record("run.start", %{error: message}, :error)
    end
  end

  def launch(run, _on_prompt, _label, _placement), do: run

  # The first prompt can reach MCP before agent.prompt returns. Publish the parent's
  # identity first, while keeping it in :starting until launch completes.
  defp record_launch_pane(%Run{spawned_by_run_id: nil}, :pane, _info), do: :ok

  defp record_launch_pane(%Run{spawned_by_run_id: nil} = run, :agent, info) do
    progress(get_run(run.id), info)
    :ok
  end

  defp record_launch_pane(run, stage, info) do
    attrs = if stage == :agent, do: %{status: :working, started_at: now()}, else: %{}
    progress(get_run(run.id), Map.merge(info, attrs))
    :ok
  end

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

  @doc "Closes the run’s tab (or its legacy pane) and marks the run stopped."
  def stop_run(%Run{kind: "mix"}), do: {:error, "Mix runs finish on their own."}

  def stop_run(%Run{} = run) do
    if Run.active?(run) do
      run |> Launcher.close() |> finish_stop(run)
    else
      {:error, "The run is not active."}
    end
  end

  defp finish_stop({:ok, how}, run) do
    run
    |> progress(%{status: :stopped, finished_at: now()})
    |> record("run.stop", %{pane: how}, :ok)
    |> then(&{:ok, &1})
  end

  defp finish_stop({:error, message}, run) do
    record(run, "run.stop", %{error: message}, :error)
    {:error, message}
  end

  @doc false
  def fail_subagent(%Run{spawned_by_run_id: id} = run, reason) when is_binary(id) do
    run
    |> progress(%{status: :failed, finished_at: now(), result: %{error: reason}})
    |> record("run.status", %{to: "failed", reason: reason}, :error)
  end

  @doc "An agent's final result (via MCP): finishes the run and cancels open questions."
  def submit_result(run_id, summary, artifacts) do
    case get_run(run_id) do
      %Run{spawned_by_run_id: id} when is_binary(id) ->
        Jarvis2.Subagents.synchronize(id, fn ->
          submit_result_locked(run_id, summary, artifacts)
        end)

      _ ->
        submit_result_locked(run_id, summary, artifacts)
    end
  end

  defp submit_result_locked(run_id, summary, artifacts) do
    with %Run{} = run <- get_run(run_id),
         true <- Run.active?(run),
         :ok <- valid_result(run, summary, artifacts) do
      updated =
        progress(run, %{
          status: :done,
          finished_at: now(),
          result: %{summary: summary, artifacts: artifacts}
        })

      Questions.cancel_for_run(run.id)
      if is_nil(run.spawned_by_run_id), do: Jarvis2.Subagents.stop_all(run.id)
      record(updated, "run.result", %{artifacts: length(artifacts)})
      {:ok, updated}
    else
      {:error, _} = error -> error
      _ -> {:error, "The run is not active."}
    end
  end

  defp valid_result(run, summary, artifacts) do
    max = if run.spawned_by_run_id, do: 32_768, else: 2_000

    cond do
      not is_binary(summary) or byte_size(summary) == 0 ->
        {:error, "summary or artifacts are invalid or too long"}

      byte_size(summary) > max ->
        {:error, "summary exceeds #{max} bytes; shorten it"}

      not String.valid?(summary) or not valid_artifacts?(artifacts) ->
        {:error, "summary or artifacts are invalid or too long"}

      true ->
        :ok
    end
  end

  defp valid_artifacts?(artifacts) when is_list(artifacts),
    do:
      length(artifacts) <= 20 and Enum.all?(artifacts, &(is_binary(&1) and byte_size(&1) <= 500))

  defp valid_artifacts?(_), do: false

  def prompt_run(%Run{} = run, text, opts \\ []) when is_binary(text) do
    cond do
      text == "" ->
        {:error, "Write something to send."}

      not Jarvis2.Herdr.Actions.valid_prompt_text?(text) ->
        {:error, "The prompt is invalid or too long (maximum 65536 bytes)."}

      String.trim(text) == "" ->
        {:error, "Write something to send."}

      not Run.active?(run) ->
        {:error, "The run is not active."}

      true ->
        Launcher.prompt(run, String.trim(text), opts)
    end
  end

  @doc """
  Brings active runs in line with a fresh mirror view and returns the updated `seen` map of last
  observed agent statuses. A run is `done` when its agent goes from working or blocked to idle.
  """
  def apply_view(%{stale: false, snapshot: snapshot} = view, seen) when is_map(snapshot) do
    seen =
      Enum.reduce(active_runs(), seen, fn run, seen ->
        if run.spawned_by_run_id, do: seen, else: reconcile(run, view, seen)
      end)

    Jarvis2.Subagents.tick(view, seen)
  end

  def apply_view(_view, seen), do: seen

  defp reconcile(%Run{status: :starting} = run, _view, seen) do
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

  @doc false
  def transition_subagent(%Run{spawned_by_run_id: id} = run, status, reason \\ nil)
      when is_binary(id) do
    attrs = %{status: status}

    attrs =
      if status in [:failed, :lost, :stopped],
        do: Map.put(attrs, :finished_at, now()),
        else: attrs

    run |> progress(attrs) |> record("run.status", %{to: status, reason: reason})
  end

  defp progress(run, attrs) do
    # Round-trip the result so the returned run matches what a reload would give.
    attrs = Map.update(attrs, :result, nil, &(&1 && &1 |> Jason.encode!() |> Jason.decode!()))
    attrs = if attrs.result, do: attrs, else: Map.delete(attrs, :result)

    {:ok, run} = run |> Run.progress_changeset(attrs) |> Repo.update()

    if run.status in [:failed, :lost, :stopped] do
      Questions.cancel_for_run(run.id)
      if is_nil(run.spawned_by_run_id), do: Jarvis2.Subagents.stop_all(run.id)
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
    values = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    Map.merge(
      defaults,
      Map.reject(values, fn {key, value} -> key in ["model", "thinking"] and is_nil(value) end)
    )
  end

  defp now, do: DateTime.utc_now()
end
