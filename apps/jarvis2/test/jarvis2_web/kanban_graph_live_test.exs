defmodule Jarvis2Web.KanbanGraphLiveTest do
  use Jarvis2Web.ConnCase, async: false
  alias Jarvis2.Kanban

  setup %{conn: conn}, do: %{conn: sign_in(conn)}

  test "reviews proposed edges, highlights paths, and applies the checked choices", %{conn: conn} do
    alias Jarvis2.{Repo, Runs}
    alias Jarvis2.Kanban.{Arrange, Card}
    cwd = File.cwd!()
    {:ok, a} = Kanban.create_card(%{title: "A", cwd: cwd})
    {:ok, b} = Kanban.create_card(%{title: "B", cwd: cwd})
    {:ok, c} = Kanban.create_card(%{title: "C", cwd: cwd})
    {:ok, _} = Kanban.add_dependency(b, a)
    {:ok, run} = Runs.create_run(%{name: "arrange", cwd: cwd, task: "test"})
    arrange = cwd |> Card.arrange_changeset(Arrange.snapshot(cwd)) |> Repo.insert!()
    arrange |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

    assert {:error, "arrangements cannot have dependencies"} = Kanban.add_dependency(b, arrange)
    assert {:error, "arrangements cannot have dependencies"} = Kanban.add_dependency(arrange, b)

    refute Enum.any?(
             Jarvis2.Kanban.Dependencies.candidates(b, Kanban.graph(cwd)),
             &(&1.id == arrange.id)
           )

    proposal =
      Jason.encode!(%{
        considered: [a.id, b.id, c.id],
        edges: [
          %{card: c.id, blocked_by: b.id, needs: "done", reason: "uses B"},
          %{card: a.id, blocked_by: b.id, needs: "done", reason: "cycle"}
        ]
      })

    {:ok, _} = Kanban.submit_deliverable(run.id, proposal)
    run |> Ecto.Changeset.change(status: :stopped) |> Repo.update!()
    {:ok, view, _} = live(conn, "/kanban/graph?cwd=#{URI.encode_www_form(cwd)}")
    assert has_element?(view, "#arrangement-review", "uses B")
    assert has_element?(view, "#proposal-0 .graph-proposal")
    assert has_element?(view, "#proposal-1 .proposal-invalid")
    assert has_element?(view, "#arrangement-review", "cycle")
    view |> element("#graph-node-#{b.id}") |> render_click()
    assert has_element?(view, "#graph-node-#{a.id}.related")
    assert has_element?(view, "#graph-node-#{b.id}.related")
    view |> form("#arrangement-review", %{selected: ["0"]}) |> render_submit()
    assert {:blocked, [_]} = Kanban.dependency_state(c)
    assert Kanban.get_card(arrange.id).column == :archive
    refute has_element?(view, "#arrangement-review")
  end

  test "threshold controls the board nudge and disables at zero", %{conn: conn} do
    cwd = File.cwd!()
    for n <- 1..3, do: Kanban.create_card(%{title: "Unarranged #{n}", cwd: cwd})
    {:ok, view, _} = live(conn, "/kanban")
    assert has_element?(view, ".banner", "3 Scratch cards")
    assert has_element?(view, ".badge", "Unarranged")
    assert {:ok, _} = Jarvis2.Settings.update(%{arrange_nudge_threshold: 0})
    {:ok, view, _} = live(conn, "/kanban")
    refute has_element?(view, ".banner", "not been arranged")
    assert {:error, _} = Jarvis2.Settings.update(%{arrange_nudge_threshold: 51})
    assert {:error, _} = Jarvis2.Settings.update(%{arrange_nudge_threshold: -1})
  end

  test "the Arrange card panel uses the shared review and can dismiss without changes", %{
    conn: conn
  } do
    alias Jarvis2.{Repo, Runs}
    alias Jarvis2.Kanban.{Arrange, Card}
    cwd = File.cwd!()
    {:ok, a} = Kanban.create_card(%{title: "A", cwd: cwd})
    {:ok, run} = Runs.create_run(%{name: "arrange", cwd: cwd, task: "test"})
    arrange = cwd |> Card.arrange_changeset(Arrange.snapshot(cwd)) |> Repo.insert!()
    arrange |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
    {:ok, _} = Kanban.submit_deliverable(run.id, Jason.encode!(%{considered: [a.id], edges: []}))
    run |> Ecto.Changeset.change(status: :stopped) |> Repo.update!()
    {:ok, view, _} = live(conn, "/kanban/cards/#{arrange.id}")
    assert has_element?(view, "#arrangement-review", "considered, no dependency")
    assert has_element?(view, "#arrangement-review a", "Ask for changes")
    refute has_element?(view, "#deliverable-#{arrange.id}")
    view |> element("#arrangement-review button", "Dismiss") |> render_click()
    assert Kanban.get_card(arrange.id).column == :archive
    assert is_nil(Kanban.get_card(a.id).arranged_at)
    assert Kanban.graph(cwd).edges == []
  end

  test "filters retain archived blockers and preserve worktree lanes in the URL", %{conn: conn} do
    cwd = File.cwd!()
    {:ok, a} = Kanban.create_card(%{title: "Archived blocker", cwd: cwd})
    {:ok, b} = Kanban.create_card(%{title: "Blocked card", cwd: cwd, worktree: "feature"})
    {:ok, _} = Kanban.add_dependency(b, a)
    {:ok, _} = Kanban.move(a, :archive)

    {:ok, view, _} =
      live(conn, "/kanban/graph?cwd=#{URI.encode_www_form(cwd)}&hide=1&lanes=worktree")

    assert has_element?(view, "#graph-node-#{a.id}")
    assert has_element?(view, "#graph-node-#{b.id}")
    assert render(view) =~ "other worktree"
    assert render(view) =~ "feature"
    assert has_element?(view, "#graph-filters input[name=lanes][checked]")
  end

  test "shows a project graph, panel, ready cards and live changes", %{conn: conn} do
    cwd = File.cwd!()
    {:ok, a} = Kanban.create_card(%{title: "Schema", cwd: cwd})
    {:ok, b} = Kanban.create_card(%{title: "Endpoint", cwd: cwd, worktree: "feature"})
    {:ok, other} = Kanban.create_card(%{title: "Other", cwd: "/tmp"})
    {:ok, _} = Kanban.add_dependency(b, a)
    {:ok, view, _} = live(conn, "/kanban/graph?cwd=#{URI.encode_www_form(cwd)}")
    assert has_element?(view, "#graph-node-#{a.id}", "Schema")
    assert has_element?(view, "#graph-node-#{b.id}", "Endpoint")
    refute has_element?(view, "#graph-node-#{other.id}")
    assert has_element?(view, "#graph-edge-#{a.id}-#{b.id}")
    assert has_element?(view, "#ready-now", "Schema")
    refute has_element?(view, "#ready-now", "Endpoint")
    view |> element("#graph-node-#{b.id}") |> render_click()
    assert has_element?(view, "#graph-panel", "Endpoint")
    assert has_element?(view, "#dependencies-#{b.id}", "Schema")
    {:ok, _} = Kanban.remove_dependency(b, a)
    assert has_element?(view, "#not-connected", "Endpoint")
    refute has_element?(view, "#graph-edge-#{a.id}-#{b.id}")
  end
end
