# Invoked only by live-tour.sh with an isolated test database, Herdr session, and mock model.
import Ecto.Query
alias Jarvis2.{Kanban, Repo, Runs}
alias Jarvis2.Herdr.{Events, Mirror, Session, Socket, Workspaces}
alias Jarvis2.Runs.{Monitor, Run}

defmodule LiveReviewTour do
  def wait(label, fun, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(label, fun, deadline)
  end

  defp poll(label, fun, deadline) do
    case fun.() do
      nil -> retry(label, fun, deadline)
      false -> retry(label, fun, deadline)
      value -> value
    end
  end

  defp retry(label, fun, deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: raise("timeout: #{label}")
    Process.sleep(200)
    poll(label, fun, deadline)
  end
end

:ok = Supervisor.terminate_child(Jarvis2.Supervisor, Repo)
repo_config = Application.fetch_env!(:jarvis2, Repo)

Application.put_env(
  :jarvis2,
  Repo,
  repo_config |> Keyword.put(:pool, DBConnection.ConnectionPool) |> Keyword.put(:pool_size, 4)
)

{:ok, _} = Supervisor.restart_child(Jarvis2.Supervisor, Repo)
Application.put_env(:jarvis2, :live_scenarios, [:subagents])
port = String.to_integer(System.fetch_env!("TOUR_PORT"))
endpoint = Application.fetch_env!(:jarvis2, Jarvis2Web.Endpoint)
Application.put_env(:jarvis2, Jarvis2Web.Endpoint, Keyword.put(endpoint, :http, port: port))
{:ok, path} = Session.ensure("jarvis2")
{:ok, _} = Supervisor.start_child(Jarvis2.Supervisor, {Socket, path: path})
{:ok, _} = Supervisor.start_child(Jarvis2.Supervisor, {Events, path: path})
{:ok, _} = Supervisor.start_child(Jarvis2.Supervisor, Monitor)
{:ok, _} = Bandit.start_link(plug: Jarvis2Web.Endpoint, ip: {127, 0, 0, 1}, port: port)

LiveReviewTour.wait("Herdr mirror", fn -> match?(%{stale: false}, Mirror.get()) end)
root = System.fetch_env!("TOUR_REPO")
{:ok, workspace} = Workspaces.resolve(root, "tour-linked")
cwd = workspace.checkout_path
{:ok, main} = Workspaces.resolve(cwd, "main")

if main.workspace_id == workspace.workspace_id or main.checkout_path == cwd,
  do: raise("resolving main did not reproduce the linked-worktree workspace trap")

Mirror.invalidate()

anchor =
  LiveReviewTour.wait("linked-worktree anchor pane", fn ->
    view = Mirror.get()

    if not view.stale,
      do: Enum.find(view.snapshot["panes"], &(&1["workspace_id"] == workspace.workspace_id))
  end)

anchor_pane = anchor["pane_id"]
tab = anchor["tab_id"]

for mode <- ["NORMAL", "BLOCKED"] do
  focused = Mirror.get().snapshot["focused_pane_id"]
  File.write!(Path.join(cwd, "sample.txt"), "initial\n")

  {:ok, run} =
    Runs.create_run(%{
      name: "implementer",
      role: "implementer",
      kind: "pi",
      model: "mock/mock",
      thinking: "off",
      task: "TOUR_#{mode}",
      cwd: cwd,
      worktree: "tour-linked",
      session_id: Ecto.UUID.generate()
    })

  {:ok, card} =
    Kanban.create_card(%{title: "Review #{mode}", cwd: cwd, worktree: "tour-linked", kind: :plan})

  card
  |> Ecto.Changeset.change(column: :agent, stage: :implementation, run_id: run.id)
  |> Repo.update!()

  parent = Runs.launch(run, fn _ -> :ok end, "implementer", {:split, anchor_pane, tab})

  if parent.status != :working,
    do: raise("implementer failed to start: #{inspect(parent.result)}")

  child =
    LiveReviewTour.wait("#{mode} child launch", fn ->
      Repo.one(from(r in Run, where: r.spawned_by_run_id == ^run.id))
    end)

  child =
    LiveReviewTour.wait("#{mode} child pane", fn ->
      child = Runs.get_run(child.id)
      if child.pane_id && child.started_at, do: child
    end)

  if child.tab_id != tab or child.workspace_id != parent.workspace_id or child.cwd != parent.cwd or
       child.worktree != parent.worktree,
     do: raise("child not split beside the implementer")

  split_width =
    LiveReviewTour.wait("#{mode} split geometry", fn ->
      view = Mirror.get()
      layout = if not view.stale, do: Enum.find(view.snapshot["layouts"], &(&1["tab_id"] == tab))

      if layout && Enum.any?(layout["panes"], &(&1["pane_id"] == child.pane_id)) do
        pane = Enum.find(layout["panes"], &(&1["pane_id"] == parent.pane_id))
        pane && pane["rect"]["width"]
      end
    end)

  LiveReviewTour.wait("#{mode} result", fn ->
    current = Runs.get_run(child.id)
    if current.result && current.result["summary"], do: current
  end)

  LiveReviewTour.wait("#{mode} child finished", fn ->
    Runs.get_run(child.id).status == :finished
  end)

  Mirror.invalidate()

  LiveReviewTour.wait("#{mode} pane closed", fn ->
    view = Mirror.get()
    not view.stale and not Enum.any?(view.snapshot["panes"], &(&1["pane_id"] == child.pane_id))
  end)

  snapshot = Mirror.get().snapshot
  panes = Enum.map(snapshot["panes"], & &1["pane_id"])

  unless anchor_pane in panes and parent.pane_id in panes,
    do: raise("closing child removed another pane")

  layout = Enum.find(snapshot["layouts"], &(&1["tab_id"] == tab))
  parent_rect = Enum.find(layout["panes"], &(&1["pane_id"] == parent.pane_id))["rect"]
  unless parent_rect["width"] > split_width, do: raise("layout did not reflow after child close")
  if snapshot["focused_pane_id"] != focused, do: raise("review split or close stole focus")
  requests = File.read!(System.fetch_env!("TOUR_REQUEST_LOG"))

  unless requests =~ "TOUR_ENV run=#{child.id} pane=#{child.pane_id}",
    do: raise("child did not inherit its run and pane environment")

  sessions =
    Path.wildcard(
      Path.join([
        System.fetch_env!("PI_CODING_AGENT_DIR"),
        "sessions",
        "**",
        "*#{child.session_id}*.jsonl"
      ])
    )

  [session] = sessions
  entries = session |> File.stream!() |> Enum.map(&Jason.decode!/1)

  unless length(entries) > 1 and File.read!(session) =~ "submit_result",
    do: raise("child session was not retained after pane close")

  if mode == "BLOCKED" do
    awaiting =
      LiveReviewTour.wait("blocked review question", fn ->
        card = Kanban.get_card(card.id)
        if card.column == :awaiting_user, do: card
      end)

    [round] = Enum.filter(awaiting.rounds, &(&1.status == :open))
    [question] = round.questions

    {:ok, round} =
      Kanban.save_draft(round, %{question["id"] => %{kind: "custom", text: "TOUR_ANSWER"}})

    {:ok, _} = Kanban.submit_answers(round)
    IO.puts("PASS blocked report routed to board after pane closed")
  end

  completed =
    LiveReviewTour.wait("#{mode} implementation completion", fn ->
      card = Kanban.get_card(card.id)
      if card.column == :done, do: card
    end)

  unless completed.deliverable =~ "Fix review", do: raise("missing Fix review in deliverable")

  unless File.read!(Path.join(cwd, "sample.txt")) == "initial\nreview-fixed\n",
    do: raise("implementer did not apply the review")

  if mode == "BLOCKED" and not String.contains?(completed.deliverable, "TOUR_ANSWER"),
    do: raise("answer did not resume implementer")

  IO.puts("PASS #{mode} report received, child closed, implementer completed")
end
