defmodule Jarvis2.CardDependenciesTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.{Kanban, Repo}

  defp card(title, attrs \\ %{}) do
    {:ok, card} = Kanban.create_card(Map.merge(%{title: title, cwd: File.cwd!()}, attrs))
    card
  end

  test "validates project, scratch, need, duplicates and cycles" do
    a = card("A")
    b = card("B")
    c = card("C")
    other = card("Other", %{cwd: "/tmp"})
    research = card("Research", %{kind: :research})

    assert {:error, _} = Kanban.add_dependency(a, a)
    assert {:error, _} = Kanban.add_dependency(a, other)
    assert {:error, _} = Kanban.add_dependency(a, research, needs: :plan)
    assert {:ok, _} = Kanban.add_dependency(a, b)
    assert {:error, _} = Kanban.add_dependency(a, b)
    assert {:error, reason} = Kanban.add_dependency(b, a)
    assert reason =~ "cycle"
    assert {:ok, _} = Kanban.add_dependency(b, c)
    assert {:error, reason} = Kanban.add_dependency(c, a)
    assert reason =~ "cycle"
    assert reason =~ "A"

    a |> Ecto.Changeset.change(column: :agent) |> Repo.update!()
    assert {:error, _} = Kanban.add_dependency(a, c)
    assert {:error, _} = Kanban.remove_dependency(a, b)
  end

  test "blocks starts, distinguishes accepted plans and completed implementations, and warns of staleness" do
    dependent = card("Dependent")
    prereq = card("Design")
    assert {:ok, _} = Kanban.add_dependency(dependent, prereq, needs: :done)
    assert {:blocked, [edge]} = Kanban.dependency_state(dependent)
    assert edge.blocked_by_card.id == prereq.id
    assert {:error, message} = Kanban.move(dependent, :agent)
    assert message =~ "Blocked by: Design (needs done)"
    assert Kanban.get_card(dependent.id).column == :scratch

    prereq |> Ecto.Changeset.change(column: :done, deliverable: "plan") |> Repo.update!()
    assert {:blocked, _} = Kanban.dependency_state(dependent)
    prereq |> Ecto.Changeset.change(column: :done, stage: :implementation) |> Repo.update!()
    assert {:blocked, _} = Kanban.dependency_state(dependent)
    {:ok, run} = Jarvis2.Runs.create_run(%{name: "Design", task: "test", cwd: prereq.cwd})
    prereq |> Ecto.Changeset.change(run_id: run.id) |> Repo.update!()
    assert {:ready, []} = Kanban.dependency_state(dependent)
    dependent |> Ecto.Changeset.change(column: :agent) |> Repo.update!()
    prereq |> Ecto.Changeset.change(column: :agent) |> Repo.update!()
    assert {:stale, [_]} = Kanban.dependency_state(dependent)
    prereq |> Ecto.Changeset.change(column: :archive) |> Repo.update!()
    assert {:stale, [_]} = Kanban.dependency_state(dependent)

    never_run = card("Never-run plan")
    never_run |> Ecto.Changeset.change(accepted_plan: "unexpected") |> Repo.update!()
    uses_never_run = card("Uses never-run plan")
    assert {:ok, _} = Kanban.add_dependency(uses_never_run, never_run, needs: :plan)
    assert {:blocked, [_]} = Kanban.dependency_state(uses_never_run)

    plan_dependent = card("Uses design")
    assert {:ok, _} = Kanban.add_dependency(plan_dependent, prereq, needs: :plan)
    assert {:blocked, _} = Kanban.dependency_state(plan_dependent)
    prereq |> Ecto.Changeset.change(column: :agent, accepted_plan: "accepted") |> Repo.update!()
    assert {:ready, []} = Kanban.dependency_state(plan_dependent)
    prereq |> Ecto.Changeset.change(column: :archive, accepted_plan: "accepted") |> Repo.update!()
    assert {:blocked, _} = Kanban.dependency_state(plan_dependent)
  end

  test "deleting either card cascades dependencies" do
    a = card("A")
    b = card("B")
    assert {:ok, _} = Kanban.add_dependency(a, b)
    Repo.delete!(b)
    assert {:none, []} = Kanban.dependency_state(a)
    b = card("B2")
    assert {:ok, _} = Kanban.add_dependency(a, b)
    Repo.delete!(a)
    assert Kanban.graph(b.cwd).edges == []
  end

  test "creating a card with prerequisites is atomic and marks it arranged" do
    a = card("A")
    before_count = length(Kanban.list_cards())
    attrs = %{title: "new", cwd: a.cwd}

    assert {:error, _} =
             Kanban.create_card_with_dependencies(attrs, [a.id, Ecto.UUID.generate()],
               source: :harness
             )

    assert length(Kanban.list_cards()) == before_count
    assert {:ok, created} = Kanban.create_card_with_dependencies(attrs, [a.id], source: :harness)
    assert created.arranged_at
    assert {:blocked, [%{source: :harness}]} = Kanban.dependency_state(created)
  end

  test "start prompts include bounded prerequisite results and worktree warning" do
    dependent = card("Dependent", %{worktree: "feature"})
    prerequisite = card("Design", %{worktree: "other"})

    prerequisite =
      prerequisite
      |> Ecto.Changeset.change(
        column: :done,
        stage: :implementation,
        deliverable: String.duplicate("é", 5_000)
      )
      |> Repo.update!()

    {:ok, _} = Kanban.add_dependency(dependent, prerequisite)
    role = %Jarvis2.Roles.Role{prompt: "Do the work."}

    prompt =
      Jarvis2.Kanban.Prompt.build(dependent, [], nil,
        role: role,
        prerequisites: Jarvis2.Kanban.Dependencies.edges(dependent)
      )

    assert prompt =~ "Prerequisites"
    assert prompt =~ "Design"
    assert prompt =~ "worktree `other`; it is not in your checkout"
    assert prompt =~ "/kanban/cards/#{prerequisite.id}"
    refute prompt =~ prerequisite.deliverable
    assert byte_size(prompt) < 14_000
    assert String.valid?(prompt)
  end

  test "prompt retains a pointer to every prerequisite when results exceed the total budget" do
    dependent = card("Dependent")

    cards =
      for n <- 1..5 do
        prerequisite = card("Prerequisite #{n}", %{kind: :research})

        prerequisite
        |> Ecto.Changeset.change(column: :done, deliverable: String.duplicate("x", 8_000))
        |> Repo.update!()

        {:ok, _} = Kanban.add_dependency(dependent, prerequisite)
        prerequisite
      end

    role = %Jarvis2.Roles.Role{prompt: "Do the work."}

    prompt =
      Jarvis2.Kanban.Prompt.build(dependent, [], nil,
        role: role,
        prerequisites: Jarvis2.Kanban.Dependencies.edges(dependent)
      )

    for prerequisite <- cards do
      assert prompt =~ "/kanban/cards/#{prerequisite.id}"
      assert prompt =~ prerequisite.title
    end

    assert byte_size(prompt) < 14_000
  end

  test "opposite concurrent additions cannot both succeed" do
    a = card("A")
    b = card("B")

    results =
      [{a, b}, {b, a}]
      |> Task.async_stream(fn {x, y} -> Kanban.add_dependency(x, y) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
  end
end
