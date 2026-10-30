defmodule Jarvis2.AgentsFileKanbanTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.{Journal, Kanban, Runs}

  defmodule Mirror do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(_), do: {:ok, %{stale: false, snapshot: %{}}}
    def handle_call(:get, _, state), do: {:reply, state, state}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "agents-kanban-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, card} = Kanban.create_card(%{title: "Context", kind: :agents_file, cwd: dir})
    {:ok, run} = Runs.create_run(%{name: "writer", task: "test", cwd: dir})
    run |> Ecto.Changeset.change(status: :stopped) |> Repo.update!()
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
    assert :ok = Kanban.begin_agents_file_run(run.id, dir)
    %{dir: dir, card: card, run: run}
  end

  defp proposal(text), do: Jason.encode!(%{content: text, changes: []})

  test "validates and rejects either context file changing during a run", %{
    dir: dir,
    card: card,
    run: run
  } do
    assert {:error, message} = Kanban.submit_deliverable(run.id, "bad")
    assert message =~ "JSON"
    File.write!(Path.join(dir, "CLAUDE.md"), "changed")
    assert {:error, message} = Kanban.submit_deliverable(run.id, proposal("new"))
    assert message =~ "CLAUDE.md"
    assert Kanban.get_card(card.id).column == :agent
    assert :ok = Kanban.begin_agents_file_run(run.id, dir)
    File.write!(Path.join(dir, "AGENTS.md"), "changed")
    assert {:error, message} = Kanban.submit_deliverable(run.id, proposal("new"))
    assert message =~ "AGENTS.md"
  end

  test "apply detects staleness, archives and journals without content", %{
    dir: dir,
    card: card,
    run: run
  } do
    assert {:ok, _} = Kanban.submit_deliverable(run.id, proposal("private proposed text\n"))
    done = Kanban.get_card(card.id)
    File.write!(Path.join(dir, "AGENTS.md"), "external edit")
    assert {:error, message} = Kanban.apply_agents_file(done)
    assert message =~ "changed"
    assert File.read!(Path.join(dir, "AGENTS.md")) == "external edit"
    assert Kanban.get_card(card.id).column == :done
    File.rm!(Path.join(dir, "AGENTS.md"))
    File.write!(Path.join(dir, "CLAUDE.md"), "post-submit change")
    assert {:ok, _} = Kanban.apply_agents_file(done)
    assert Kanban.get_card(card.id).column == :archive
    assert File.read!(Path.join(dir, "AGENTS.md")) == "private proposed text\n"
    assert File.read!(Path.join(dir, "CLAUDE.md")) == "post-submit change"

    assert [%{payload: %{"content_bytes" => 22}} = event] =
             Journal.recent(type: "kanban.agents_file_applied")

    refute inspect(event) =~ "private proposed text"
  end

  test "reopening an active run records the new baseline before delivering feedback", %{
    dir: dir,
    card: card,
    run: run
  } do
    run |> Ecto.Changeset.change(status: :working) |> Repo.update!()
    assert {:ok, _} = Kanban.submit_deliverable(run.id, proposal("first"))
    File.write!(Path.join(dir, "AGENTS.md"), "changed after submit")
    old_mirror = Application.fetch_env(:jarvis2, :mirror)
    old_wait = Application.fetch_env(:jarvis2, :kanban_delivery_wait_ms)
    {:ok, mirror} = start_supervised(Mirror)
    Application.put_env(:jarvis2, :mirror, mirror)
    Application.put_env(:jarvis2, :kanban_delivery_wait_ms, 0)

    on_exit(fn ->
      for {key, value} <- [mirror: old_mirror, kanban_delivery_wait_ms: old_wait] do
        case value do
          {:ok, value} -> Application.put_env(:jarvis2, key, value)
          :error -> Application.delete_env(:jarvis2, key)
        end
      end
    end)

    assert {:ok, reopened} = Kanban.reopen(Kanban.get_card(card.id), "Keep the changes")
    assert reopened.column == :agent
    assert {:ok, _} = Kanban.submit_deliverable(run.id, proposal("second"))
  end

  test "the checkout path selected at launch is used for baseline and apply", %{
    dir: dir,
    card: card,
    run: run
  } do
    linked = Path.join(dir, "worktree")
    File.mkdir_p!(linked)
    File.write!(Path.join(dir, "AGENTS.md"), "main")
    File.write!(Path.join(linked, "AGENTS.md"), "worktree")
    assert :ok = Kanban.begin_agents_file_run(run.id, linked)
    run |> Ecto.Changeset.change(cwd: linked) |> Repo.update!()
    assert {:ok, _} = Kanban.submit_deliverable(run.id, proposal("revised"))
    assert {:ok, _} = Kanban.apply_agents_file(Kanban.get_card(card.id))
    assert File.read!(Path.join(dir, "AGENTS.md")) == "main"
    assert File.read!(Path.join(linked, "AGENTS.md")) == "revised"
  end

  test "an outdated card cannot be applied", %{card: card, run: run, dir: dir} do
    assert {:ok, _} = Kanban.submit_deliverable(run.id, proposal("new"))
    done = Kanban.get_card(card.id)

    done
    |> Ecto.Changeset.change(updated_at: DateTime.add(done.updated_at, 1, :second))
    |> Repo.update!()

    assert {:error, message} = Kanban.apply_agents_file(done)
    assert message =~ "reload"
    refute File.exists?(Path.join(dir, "AGENTS.md"))
  end
end
