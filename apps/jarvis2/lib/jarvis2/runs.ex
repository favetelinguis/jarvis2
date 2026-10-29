defmodule Jarvis2.Runs do
  @moduledoc """
  Agent jobs started from the UI. A run is created in the database first; the Herdr side effects
  then happen through `Jarvis2.Runs.Launcher`, and the monitor keeps the status in step with what
  Herdr reports. Changes are broadcast on `"runs"` and `"run:<id>"`.
  """
  import Ecto.Query

  alias Jarvis2.{Journal, Repo}
  alias Jarvis2.Runs.{Launcher, Run}

  @topic "runs"
  @stale_start_ms 120_000

  def topic, do: @topic

  def defaults, do: %{kind: "pi", model: "openrouter/openai/gpt-6-luna", thinking: "low"}

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

  @doc "Closes the run's pane (when it is still ours) and marks the run stopped."
  def stop_run(%Run{} = run) do
    if Run.active?(run) or run.status == :dry_run do
      case Launcher.close(run) do
        {:ok, how} ->
          run
          |> progress(%{status: :stopped, finished_at: now()})
          |> record("run.stop", %{pane: how}, if(how == :dry_run, do: :dry_run, else: :ok))
          |> then(&{:ok, &1})

        {:error, message} ->
          record(run, "run.stop", %{error: message}, :error)
          {:error, message}
      end
    else
      {:error, "The run is not active."}
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
    broadcast(run)
    run
  end

  defp record(run, type, payload, outcome \\ :ok) do
    Journal.record(%{source: :ui, type: type, run_id: run.id, outcome: outcome, payload: payload})
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
