defmodule Jarvis2.RunsTest do
  use Jarvis2.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Jarvis2.{Journal, Runs}
  alias Jarvis2.Herdr.{ExecutionGuard, PromptGuard}
  alias Jarvis2.Runs.{Launcher, Monitor, Run}

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
    def handle_call({:put, view}, _from, _), do: {:reply, :ok, view}
    def handle_cast(:invalidate, view), do: {:noreply, view}
  end

  setup do
    {:ok, mirror} = start_supervised({Mirror, view()})
    {:ok, exec} = start_supervised({ExecutionGuard, [name: nil]})
    {:ok, prompts} = start_supervised({PromptGuard, [name: nil]})
    {:ok, behavior} = start_supervised({Agent, fn -> %{} end})
    parent = self()

    dir =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "runs-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "herdr.sock")

    handler = fn request ->
      send(parent, {:request, request["method"], request["params"]})
      respond(request, mirror, Agent.get(behavior, & &1))
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Jarvis2.Herdr.Socket, [name: nil, path: path]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(dir)
    end)

    config(:mirror, mirror)
    config(:execution_guard, exec)
    config(:prompt_guard, prompts)
    config(:herdr_socket, socket)
    config(:mix_project_dir, dir)
    config(:live_scenarios, [])
    %{mirror: mirror, behavior: behavior, cwd: dir}
  end

  describe "create_run/1" do
    test "fills the Pi / luna / low defaults and stores a starting run", %{cwd: cwd} do
      assert {:ok, run} = Runs.create_run(%{name: "demo", task: "do it", cwd: cwd})
      assert %{kind: "pi", model: "openrouter/openai/gpt-6-luna", thinking: "low"} = run
      assert run.status == :starting
      assert [%{type: "run.created", run_id: id}] = Journal.recent()
      assert id == run.id
    end

    test "stores the spawner separately from the previous-stage parent", %{cwd: cwd} do
      {:ok, spawner} = Runs.create_run(%{name: "parent", task: "work", cwd: cwd})

      {:ok, child} =
        Runs.create_run(%{name: "child", task: "review", cwd: cwd, spawned_by_run_id: spawner.id})

      assert Runs.get_run(child.id).spawned_by_run_id == spawner.id
      assert child.parent_run_id == nil
    end

    test "validates user input", %{cwd: cwd} do
      attrs = %{name: "demo", task: "x", cwd: cwd}

      for bad <- [
            %{name: ""},
            %{task: String.duplicate("x", 65_537)},
            %{task: "bad\u0001text"},
            %{task: "bad\r"},
            %{task: <<255>>},
            %{name: "bad\u0001name"},
            %{cwd: "relative"},
            %{cwd: Path.join(cwd, "missing")},
            %{thinking: "extreme"},
            %{kind: "nope"},
            %{model: "no-slash"},
            %{model: "openrouter/gpt; rm -rf ~"},
            %{model: "openrouter/$(id)"}
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} = Runs.create_run(Map.merge(attrs, bad))
      end
    end
  end

  test "card launch uses its current role and sends long multibyte text intact", ctx do
    role_dir = Path.join(ctx.cwd, "roles")
    File.mkdir_p!(role_dir)
    role_body = String.duplicate("é quote \" ", 2_000)

    File.write!(
      Path.join(role_dir, "planner.md"),
      "---\nname: planner\nmodel: vendor/custom\neffort: high\n---\n" <> role_body
    )

    config(:roles_dir, role_dir)
    idea = String.duplicate("idea", 500)
    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Build", body: idea, cwd: ctx.cwd})
    assert {:ok, card} = Jarvis2.Kanban.move(card, :agent)
    assert card.run.role == "planner"
    assert card.run.model == "vendor/custom"
    assert card.run.thinking == "high"
    assert card.run.task =~ String.trim(role_body)
    assert card.run.task =~ idea
    refute card.run.task =~ "requirements engineer"
    assert_receive {:request, "pane.rename", %{"label" => "planner"}}, 3_000
    assert_receive {:request, "agent.start", %{"args" => args, "name" => name}}, 3_000
    assert name == Launcher.agent_name(card.run)
    assert args |> Enum.join(" ") =~ "--provider vendor --model custom --thinking high"

    assert_receive {:request, "pane.report_metadata",
                    %{
                      "pane_id" => "w1:p9",
                      "source" => "custom:jarvis2-role",
                      "agent" => "pi",
                      "display_agent" => "planner"
                    }},
                   3_000

    assert_receive {:request, "agent.prompt", %{"text" => text}}, 3_000
    assert text =~ String.trim(role_body)
    assert text =~ idea
    assert byte_size(text) > 8_192 and byte_size(text) <= 65_536
    assert String.valid?(text)
    assert_eventually(fn -> Runs.get_run(card.run_id).status == :working end)
  end

  test "new card runs use the current role override and preserve earlier run models", ctx do
    roles = Path.join(ctx.cwd, "roles")
    File.mkdir_p!(roles)
    file = Path.join(roles, "planner.md")
    File.write!(file, "---\nname: planner\nmodel: vendor/file\n---\nPlan")
    config(:roles_dir, roles)
    assert {:ok, _} = Jarvis2.Settings.save_role_model("planner", "vendor/local")

    {:ok, first} = Jarvis2.Kanban.create_card(%{title: "First", cwd: ctx.cwd})
    assert {:ok, first} = Jarvis2.Kanban.move(first, :agent)
    assert first.run.model == "vendor/local"
    assert_receive {:request, "agent.start", %{"args" => args}}, 3_000
    assert Enum.join(args, " ") =~ "--provider vendor --model local"
    assert_eventually(fn -> Runs.get_run(first.run_id).status == :working end)

    assert {:ok, _} = Jarvis2.Settings.save_role_model("planner", "")
    File.write!(file, "---\nname: planner\nmodel: vendor/updated\n---\nPlan")
    {:ok, second} = Jarvis2.Kanban.create_card(%{title: "Second", cwd: ctx.cwd})
    assert {:ok, second} = Jarvis2.Kanban.move(second, :agent)
    assert second.run.model == "vendor/updated"
    assert Runs.get_run(first.run_id).model == "vendor/local"
    assert_receive {:request, "agent.prompt", _}, 8_000
    assert_receive {:request, "agent.prompt", _}, 8_000
    assert_eventually(fn -> Runs.get_run(second.run_id).status == :working end)
  end

  test "agents file launch fingerprints the resolved worktree before agent.start", ctx do
    checkout = Path.join(ctx.cwd, "checkout")
    File.mkdir_p!(checkout)
    File.write!(Path.join(ctx.cwd, "AGENTS.md"), "main")
    File.write!(Path.join(checkout, "AGENTS.md"), "worktree")

    Agent.update(
      ctx.behavior,
      &Map.put(
        &1,
        "worktree.list",
        {:reply,
         %{
           worktrees: [
             %{path: ctx.cwd, is_linked_worktree: false, open_workspace_id: "w1"},
             %{
               path: checkout,
               branch: "feature",
               is_linked_worktree: true,
               open_workspace_id: "w1"
             }
           ]
         }}
      )
    )

    {:ok, card} =
      Jarvis2.Kanban.create_card(%{
        title: "Audit",
        kind: :agents_file,
        cwd: ctx.cwd,
        worktree: "feature"
      })

    assert {:ok, started} = Jarvis2.Kanban.move(card, :agent)
    assert_receive {:request, "agent.start", _}, 3_000
    assert {:ok, base} = Jarvis2.Kanban.AgentsFile.fingerprint(checkout)
    assert Jarvis2.Kanban.get_card(card.id).agents_file_base == base
    assert_eventually(fn -> Runs.get_run(started.run_id).status == :working end)
    assert Runs.get_run(started.run_id).cwd == checkout
    File.write!(Path.join(ctx.cwd, "AGENTS.md"), "changed main")

    assert {:ok, _} =
             Jarvis2.Kanban.submit_deliverable(
               started.run_id,
               Jason.encode!(%{content: "proposal", changes: []})
             )
  end

  test "a multibyte role reaches the exact final prompt limit", ctx do
    role_dir = Path.join(ctx.cwd, "roles")
    File.mkdir_p!(role_dir)
    config(:roles_dir, role_dir)
    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Boundary", body: "An idea", cwd: ctx.cwd})
    sample = Jarvis2.Kanban.Prompt.build(card, [], nil, role: %Jarvis2.Roles.Role{prompt: "x"})
    overhead = byte_size(Jarvis2.Runs.Prompt.build(%{name: card.title, task: sample}))
    remaining = 65_536 - overhead

    body =
      "x" <>
        String.duplicate("é", div(remaining, 2)) <> if(rem(remaining, 2) == 1, do: "x", else: "")

    File.write!(Path.join(role_dir, "planner.md"), "---\nname: planner\n---\n" <> body)
    assert {:ok, started} = Jarvis2.Kanban.move(card, :agent)
    assert_receive {:request, "agent.prompt", %{"text" => text}}, 3_000
    assert byte_size(text) == 65_536
    assert text =~ body
    assert text =~ "An idea"
    assert_eventually(fn -> Runs.get_run(started.run_id).status == :working end)
  end

  test "role omissions use settings and invalid or oversized roles refuse moves", ctx do
    role_dir = Path.join(ctx.cwd, "roles")
    File.mkdir_p!(role_dir)
    file = Path.join(role_dir, "planner.md")
    config(:roles_dir, role_dir)
    File.write!(file, "---\nname: planner\n---\nCustom role")
    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Build", cwd: ctx.cwd})
    assert {:ok, started} = Jarvis2.Kanban.move(card, :agent)
    assert started.run.model == Runs.defaults().model
    assert started.run.thinking == Runs.defaults().thinking
    assert started.run.task =~ "Custom role"
    assert_eventually(fn -> Runs.get_run(started.run_id).status == :working end)
    drain_requests()
    assert {:ok, _} = Jarvis2.Settings.save_role_model("planner", "vendor/local")

    for content <- [
          "---\nname: planner\nmodel: invalid;bad\n---\nbody",
          "---\nname: planner\n---\n" <> String.duplicate("x", 65_536)
        ] do
      File.write!(file, content)
      {:ok, next} = Jarvis2.Kanban.create_card(%{title: "Next", cwd: ctx.cwd})
      assert {:error, message} = Jarvis2.Kanban.move(next, :agent)
      assert message =~ "planner"
      assert Jarvis2.Kanban.get_card(next.id).column == :scratch
      refute_receive {:request, "tab.create", _}, 100
    end
  end

  test "invalid implementation role leaves the accepted plan file untouched", ctx do
    role_dir = Path.join(ctx.cwd, "roles")
    File.mkdir_p!(role_dir)

    File.write!(
      Path.join(role_dir, "implementer.md"),
      "---\nname: implementer\n---\n" <> String.duplicate("x", 65_536)
    )

    config(:roles_dir, role_dir)
    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Plan", cwd: ctx.cwd})
    {:ok, run} = Runs.create_run(%{name: "planner", task: "plan", cwd: ctx.cwd})

    card =
      card
      |> Ecto.Changeset.change(column: :done, deliverable: "new plan", run_id: run.id)
      |> Repo.update!()

    File.write!(Path.join(ctx.cwd, "PLAN.md"), "old plan")
    assert {:error, error} = Jarvis2.Kanban.advance(card)
    assert error =~ "implementer"
    assert File.read!(Path.join(ctx.cwd, "PLAN.md")) == "old plan"
    assert Jarvis2.Kanban.get_card(card.id).stage == :planning
    assert Jarvis2.Kanban.get_card(card.id).column == :done
    refute_receive {:request, "tab.create", _}, 100
  end

  test "complete wrapped prompt is validated at the exact byte boundary", %{cwd: cwd} do
    name = "boundary"
    overhead = byte_size(Jarvis2.Runs.Prompt.build(%{name: name, task: "x"})) - 1
    task = String.duplicate("x", 65_536 - overhead)
    assert {:ok, run} = Runs.create_run(%{name: name, task: task, cwd: cwd})
    assert byte_size(Jarvis2.Runs.Prompt.build(run)) == 65_536
    assert {:error, _} = Runs.create_run(%{name: name, task: task <> "x", cwd: cwd})
  end

  test "the real fix role and a maximum-size task fit the complete run prompt" do
    assert {:ok, role} = Jarvis2.Roles.get("fix")
    task = Jarvis2.Subagents.Prompt.build(role, String.duplicate("x", 32_768))
    prompt = Jarvis2.Runs.Prompt.build(%{name: "fix", task: task})
    assert Jarvis2.Herdr.Actions.valid_prompt_text?(prompt)
  end

  test "role presentation failures are cosmetic and legacy runs do not set them", ctx do
    Agent.update(ctx.behavior, fn behavior ->
      behavior
      |> Map.put("pane.rename", {:error, "failed"})
      |> Map.put("pane.report_metadata", {:error, "failed"})
    end)

    {:ok, run} =
      Runs.create_run(%{
        name: "demo",
        task: "work",
        cwd: ctx.cwd,
        role: "planner",
        model: "vendor/custom",
        thinking: "high"
      })

    assert Runs.launch(run).status == :working
    assert_receive {:request, "pane.rename", %{"label" => "planner"}}
    assert_receive {:request, "agent.start", _}
    assert_receive {:request, "pane.report_metadata", %{"display_agent" => "planner"}}
    :ok = GenServer.call(ctx.mirror, {:put, view()})
    drain_requests()
    {:ok, legacy} = Runs.create_run(%{name: "legacy", task: "work", cwd: ctx.cwd})
    assert Runs.launch(legacy).status == :working
    refute_receive {:request, "pane.rename", _}, 100
    refute_receive {:request, "pane.report_metadata", _}, 100
  end

  defp drain_requests do
    receive do
      {:request, _, _} -> drain_requests()
    after
      0 -> :ok
    end
  end

  test "accepting a plan creates a child run in the planner tab", ctx do
    {:ok, card} =
      Jarvis2.Kanban.create_card(%{title: "Build", cwd: ctx.cwd, stage: :implementation})

    assert card.stage == :planning
    {:ok, planner} = Runs.create_run(%{name: "planner", task: "plan", cwd: ctx.cwd})
    planner = Runs.launch(planner)
    assert_receive {:request, "tab.create", _}
    planner = planner |> Run.progress_changeset(%{status: :done}) |> Repo.update!()
    File.write!(Path.join(ctx.cwd, "PLAN.md"), "old plan")
    card |> Ecto.Changeset.change(column: :agent, run_id: planner.id) |> Repo.update!()
    assert {:ok, _} = Jarvis2.Kanban.report_skill(planner.id, "planning", "Scope")
    plan = String.duplicate("private plan", 1_500)
    {:ok, _} = Jarvis2.Kanban.submit_deliverable(planner.id, plan)
    card = Jarvis2.Kanban.get_card(card.id)
    assert {:ok, advanced} = Jarvis2.Kanban.advance(card)
    assert File.read!(Path.join(ctx.cwd, "PLAN.md")) == plan
    assert advanced.stage == :implementation
    assert advanced.column == :agent
    assert advanced.accepted_plan == plan
    assert advanced.deliverable == nil
    assert advanced.run_id != planner.id
    assert advanced.run.parent_run_id == planner.id
    assert advanced.run.task =~ "PLAN.md"
    refute advanced.run.task =~ plan
    assert byte_size(advanced.run.task) <= 65_536
    assert advanced.run.role == "implementer"
    assert_receive {:request, "pane.split", %{"target_pane_id" => "w1:p9", "env" => env}}, 3_000
    assert env["JARVIS2_RUN_ID"] == advanced.run_id
    refute_receive {:request, "tab.create", _}, 50
    assert_eventually(fn -> Runs.get_run(advanced.run_id).status == :working end)
    assert {:ok, _} = Jarvis2.Kanban.report_skill(advanced.run_id, "coding", "Implement")

    assert Enum.map(Jarvis2.Kanban.get_card(card.id).skill_uses, &{&1.stage, &1.name}) == [
             {:planning, "planning"},
             {:implementation, "coding"}
           ]

    assert Runs.get_run(advanced.run_id).tab_id == planner.tab_id
    assert {:error, _} = Jarvis2.Kanban.submit_deliverable(planner.id, "obsolete")

    assert {:ok, _} =
             Jarvis2.Kanban.ask_questions(advanced.run_id, [
               %{title: "Choice", body: "Details", recommended: "Yes"}
             ])

    assert Jarvis2.Kanban.get_card(card.id).column == :awaiting_user
    assert {:ok, _} = Jarvis2.Kanban.submit_deliverable(advanced.run_id, "report")
    done = Jarvis2.Kanban.get_card(card.id)
    assert done.accepted_plan == plan
    assert done.deliverable == "report"
    assert {:error, _} = Jarvis2.Kanban.advance(done)

    assert [%{payload: %{"card_id" => id, "plan_bytes" => bytes}}] =
             Journal.recent(type: "kanban.advanced")

    assert id == card.id
    assert bytes == byte_size(plan)
    refute inspect(Journal.recent()) =~ plan
    Runs.apply_view(view(), %{})
    assert Runs.get_run(planner.id).status == :lost
  end

  test "accept writes into the planner checkout and copies the card worktree", ctx do
    checkout = Path.join(ctx.cwd, "checkout")
    File.mkdir_p!(checkout)
    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "plan", cwd: ctx.cwd, worktree: "feature"})

    {:ok, planner} =
      Runs.create_run(%{name: "planner", task: "plan", cwd: checkout, worktree: "feature"})

    card =
      card
      |> Ecto.Changeset.change(column: :done, deliverable: "plan here", run_id: planner.id)
      |> Repo.update!()

    Agent.update(
      ctx.behavior,
      &Map.put(
        &1,
        "worktree.list",
        {:reply,
         %{
           worktrees: [
             %{path: ctx.cwd, is_linked_worktree: false, open_workspace_id: "w1"},
             %{
               path: checkout,
               branch: "feature",
               is_linked_worktree: true,
               open_workspace_id: "w1"
             }
           ]
         }}
      )
    )

    assert {:ok, advanced} = Jarvis2.Kanban.advance(card)
    assert advanced.run.worktree == "feature"
    assert File.read!(Path.join(checkout, "PLAN.md")) == "plan here"
    refute File.exists?(Path.join(ctx.cwd, "PLAN.md"))
    assert_eventually(fn -> Runs.get_run(advanced.run_id).status == :working end)
  end

  test "advance refuses invalid states and file errors without changing the card", ctx do
    {:ok, plan} = Jarvis2.Kanban.create_card(%{title: "plan", cwd: ctx.cwd})
    {:ok, other} = Jarvis2.Kanban.create_card(%{title: "review", kind: :review, cwd: ctx.cwd})
    assert other.stage == :main
    assert {:error, _} = Jarvis2.Kanban.advance(plan)
    other = other |> Ecto.Changeset.change(column: :done, deliverable: "review") |> Repo.update!()
    assert {:error, _} = Jarvis2.Kanban.advance(other)
    {:ok, planner} = Runs.create_run(%{name: "planner", task: "plan", cwd: ctx.cwd})
    plan = plan |> Ecto.Changeset.change(column: :done, run_id: planner.id) |> Repo.update!()
    assert {:error, _} = Jarvis2.Kanban.advance(plan)
    plan = plan |> Ecto.Changeset.change(deliverable: "plan") |> Repo.update!()
    :ok = GenServer.call(ctx.mirror, {:put, %{stale: true, snapshot: nil}})
    assert {:error, "Herdr" <> _} = Jarvis2.Kanban.advance(plan)
    :ok = GenServer.call(ctx.mirror, {:put, view()})
    File.mkdir!(Path.join(ctx.cwd, "PLAN.md"))
    assert {:error, "Could not write PLAN.md" <> _} = Jarvis2.Kanban.advance(plan)
    assert Jarvis2.Kanban.get_card(plan.id).column == :done
    assert Jarvis2.Kanban.get_card(plan.id).run_id == planner.id
    assert Repo.aggregate(Run, :count) == 1
    assert File.ls!(ctx.cwd) |> Enum.all?(&(not String.starts_with?(&1, ".PLAN.md-")))
  end

  test "accept falls back to a new tab when the planner pane is missing", ctx do
    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "plan", cwd: ctx.cwd})
    {:ok, planner} = Runs.create_run(%{name: "planner", task: "plan", cwd: ctx.cwd})

    card =
      card
      |> Ecto.Changeset.change(column: :done, deliverable: "plan", run_id: planner.id)
      |> Repo.update!()

    assert {:ok, advanced} = Jarvis2.Kanban.advance(card)
    assert_receive {:request, "tab.create", _}, 3_000
    refute_receive {:request, "pane.split", _}, 100
    assert_eventually(fn -> Runs.get_run(advanced.run_id).status == :working end)
  end

  test "restoring an implementation card starts that stage in a new tab", ctx do
    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "plan", cwd: ctx.cwd})
    {:ok, run} = Runs.create_run(%{name: "implementer", task: "old", cwd: ctx.cwd})
    run |> Run.progress_changeset(%{status: :stopped}) |> Repo.update!()

    card =
      card
      |> Ecto.Changeset.change(
        column: :done,
        stage: :implementation,
        accepted_plan: "private plan",
        run_id: run.id
      )
      |> Repo.update!()

    assert {:ok, _} = Jarvis2.Kanban.report_skill(run.id, "coding", "Implement")
    assert {:ok, archived} = Jarvis2.Kanban.move(card, :archive)
    assert {:ok, restored} = Jarvis2.Kanban.reopen(archived, "Continue work")
    assert [%{name: "coding", run_id: old_run_id}] = Jarvis2.Kanban.get_card(card.id).skill_uses
    assert old_run_id == run.id
    assert restored.stage == :implementation
    assert restored.run.task =~ "PLAN.md"
    assert restored.run.task =~ "Continue work"
    refute restored.run.task =~ "private plan"
    assert_receive {:request, "tab.create", _}, 3_000
    refute_receive {:request, "pane.split", _}, 100
    assert_eventually(fn -> Runs.get_run(restored.run_id).status == :working end)
  end

  test "restoring an archived worktree card resolves the checkout again", ctx do
    checkout = Path.join(ctx.cwd, "linked")
    File.mkdir_p!(checkout)
    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "plan", cwd: ctx.cwd, worktree: "feature"})
    {:ok, old} = Runs.create_run(%{name: "old", task: "old", cwd: checkout, worktree: "feature"})
    old |> Run.progress_changeset(%{status: :stopped}) |> Repo.update!()
    card = card |> Ecto.Changeset.change(column: :archive, run_id: old.id) |> Repo.update!()

    Agent.update(
      ctx.behavior,
      &Map.put(
        &1,
        "worktree.list",
        {:reply,
         %{
           worktrees: [
             %{path: ctx.cwd, is_linked_worktree: false, open_workspace_id: "w1"},
             %{
               path: checkout,
               branch: "feature",
               is_linked_worktree: true,
               open_workspace_id: "w1"
             }
           ]
         }}
      )
    )

    assert {:ok, restored} = Jarvis2.Kanban.reopen(card, "Continue")
    assert restored.run.worktree == "feature"
    assert_receive {:request, "worktree.list", %{"cwd" => project}}, 3_000
    assert project == ctx.cwd
    assert_receive {:request, "tab.create", %{"cwd" => ^checkout}}, 3_000
    assert_eventually(fn -> Runs.get_run(restored.run_id).status == :working end)
  end

  test "split timeout marks the run failed and warns against blind retries", ctx do
    :ok = GenServer.call(ctx.mirror, {:put, with_run_pane("idle")})
    Agent.update(ctx.behavior, &Map.put(&1, "pane.split", {:error, "timeout"}))
    {:ok, run} = Runs.create_run(%{name: "impl", task: "implement", cwd: ctx.cwd})
    result = Runs.launch(run, fn _ -> :ok end, nil, {:split, "w1:p9", "w1:t2"})
    assert result.status == :failed
    assert result.result["error"] =~ "may have been created"
    refute_receive {:request, "tab.create", _}, 50
  end

  test "session ids are validated and passed only to Pi", %{cwd: cwd} do
    attrs = %{name: "demo", task: "x", cwd: cwd}

    for id <- ["bad id", "bad;id", "$(id)"] do
      assert {:error, _} = Runs.create_run(Map.put(attrs, :session_id, id))
    end

    {:ok, run} = Runs.create_run(Map.put(attrs, :session_id, "a-123"))
    assert Enum.take(Launcher.agent_args(run), -2) == ["--session-id", "a-123"]
    refute "--session-id" in Launcher.agent_args(%{run | session_id: nil})
    assert Launcher.agent_args(%{run | kind: "codex"}) == []
  end

  test "launch records the tab and stop closes the whole tab", %{
    cwd: cwd,
    mirror: mirror,
    behavior: behavior
  } do
    {:ok, run} = Runs.create_run(%{name: "demo", task: "x", cwd: cwd})
    run = Runs.launch(run)
    assert run.tab_id == "w1:t2"
    assert Runs.get_run(run.id).tab_id == "w1:t2"
    Agent.update(behavior, &Map.put(&1, "tab.close", {:error, "failed"}))
    assert {:error, _} = Runs.stop_run(run)
    assert Runs.get_run(run.id).status == :working
    assert_receive {:request, "tab.close", %{"tab_id" => "w1:t2"}}
    Agent.update(behavior, &Map.delete(&1, "tab.close"))
    assert {:ok, _} = Runs.stop_run(run)
    assert_receive {:request, "tab.close", %{"tab_id" => "w1:t2"}}
    refute_receive {:request, "pane.close", _}, 50
    :ok = GenServer.call(mirror, {:put, view()})
    assert {:ok, :gone} = Launcher.close(run)
    refute_receive {:request, "tab.close", _}, 50
  end

  test "subagent pane cleanup never closes the shared tab and verifies the terminal", ctx do
    {:ok, parent} = Runs.create_run(%{name: "parent", task: "work", cwd: ctx.cwd})

    {:ok, child} =
      Runs.create_run(%{name: "fix", task: "review", cwd: ctx.cwd, spawned_by_run_id: parent.id})

    child = %{child | pane_id: "w1:p9", tab_id: "w1:t2", terminal_id: "term-run"}
    :ok = GenServer.call(ctx.mirror, {:put, with_run_pane("idle")})
    assert {:ok, :closed} = Launcher.close_pane(child)
    assert_receive {:request, "pane.close", %{"pane_id" => "w1:p9"}}
    refute_receive {:request, "tab.close", _}, 50

    assert {:ok, :gone} = Launcher.close_pane(%{child | terminal_id: "another-terminal"})
    refute_receive {:request, "pane.close", _}, 50

    child = child |> Run.progress_changeset(%{status: :working}) |> Repo.update!()
    assert {:ok, %{status: :stopped}} = Runs.stop_run(child)
    assert_receive {:request, "pane.close", %{"pane_id" => "w1:p9"}}
    refute_receive {:request, "tab.close", _}, 50
  end

  test "subagent spawn is gated, scoped, bounded, and returns a durable report", ctx do
    roles = Path.join(ctx.cwd, "roles")
    File.mkdir_p!(roles)

    File.write!(
      Path.join(roles, "fix.md"),
      "---\nname: fix\nsubagent: true\nmodel: vendor/review\neffort: medium\n---\nReview only."
    )

    config(:roles_dir, roles)
    assert {:ok, _} = Jarvis2.Settings.save_role_model("fix", "vendor/local-review")
    parent = working_run(ctx) |> Run.progress_changeset(%{tab_id: "w1:t2"}) |> Repo.update!()
    parent = parent |> Run.changeset(%{worktree: "feature"}) |> Repo.update!()

    Agent.update(
      ctx.behavior,
      &Map.put(
        &1,
        "worktree.list",
        {:reply,
         %{
           type: "worktree_list",
           worktrees: [
             %{
               path: Path.dirname(ctx.cwd),
               branch: "main",
               is_linked_worktree: false,
               open_workspace_id: "w2"
             },
             %{
               path: ctx.cwd,
               branch: "feature",
               is_linked_worktree: true,
               open_workspace_id: "w1"
             }
           ]
         }}
      )
    )

    caller = %{run_id: parent.id, pane: parent.pane_id}

    assert {:error, "subagents are disabled"} =
             Jarvis2.Subagents.spawn(parent.id, "fix", "review")

    config(:live_scenarios, [:subagents])
    assert {:error, _} = Jarvis2.Subagents.spawn(parent.id, "planner", "review")
    assert {:error, _} = Jarvis2.Subagents.spawn(parent.id, "fix", String.duplicate("x", 32_769))

    assert {:ok, %{id: id, status: "starting"}} =
             Jarvis2.MCP.Tools.call(
               "spawn_subagent",
               %{role: "fix", task: "private review task"},
               caller
             )

    assert {:error, "a subagent is already running"} =
             Jarvis2.Subagents.spawn(parent.id, "fix", "again")

    assert_receive {:request, "pane.split",
                    %{"target_pane_id" => "w1:p9", "focus" => false, "cwd" => checkout}},
                   3_000

    assert checkout == ctx.cwd
    refute_receive {:request, "tab.create", _}, 50
    refute_receive {:request, "worktree.list", _}, 50

    assert_eventually(fn -> Runs.get_run(id).status == :working end)
    child = Runs.get_run(id)
    assert child.spawned_by_run_id == parent.id

    assert {child.cwd, child.worktree, child.role, child.model, child.thinking} ==
             {parent.cwd, parent.worktree, "fix", "vendor/local-review", "medium"}

    assert_receive {:request, "agent.start", %{"args" => args}}, 3_000
    assert Enum.join(args, " ") =~ "--provider vendor --model local-review"

    assert {:error, _} = Jarvis2.Subagents.spawn(id, "fix", "nested")
    assert {:error, "no such subagent"} = Jarvis2.Subagents.wait(id, Ecto.UUID.generate(), 1)
    assert {:ok, %{status: "working"}} = Jarvis2.Subagents.wait(id, parent.id, 0)
    assert {:error, _} = Jarvis2.MCP.Tools.call("ask_human", %{prompt: "private"}, %{run_id: id})

    assert {:error, _} =
             Jarvis2.MCP.Tools.call("request_approval", %{action: "private"}, %{run_id: id})

    report = String.duplicate("review!", 500)
    assert {:ok, _} = Jarvis2.MCP.Tools.call("submit_result", %{summary: report}, %{run_id: id})
    assert {:ok, %{status: "working"}} = Jarvis2.Subagents.wait(id, parent.id, 0)
    child_view = GenServer.call(ctx.mirror, :get)
    Runs.apply_view(child_view, %{id => "working"})
    assert_receive {:request, "pane.close", %{"pane_id" => "w1:p10"}}
    refute_receive {:request, "tab.close", _}, 50
    assert {:ok, %{status: "finished", result: result}} = Jarvis2.Subagents.wait(id, parent.id, 0)
    assert result =~ "<subagent_result"
    assert result =~ report
    assert {:ok, %{result: ^result}} = Jarvis2.Subagents.wait(id, parent.id, 0)
    refute inspect(Journal.recent()) =~ "private review task"
    refute inspect(Journal.recent()) =~ report
  end

  test "concurrent spawns from one run create only one subagent", ctx do
    roles = Path.join(ctx.cwd, "roles")
    File.mkdir_p!(roles)
    File.write!(Path.join(roles, "fix.md"), "---\nname: fix\nsubagent: true\n---\nReview only.")
    config(:roles_dir, roles)
    config(:live_scenarios, [:subagents])
    parent = working_run(ctx) |> Run.progress_changeset(%{tab_id: "w1:t2"}) |> Repo.update!()

    results =
      1..2
      |> Task.async_stream(fn _ -> Jarvis2.Subagents.spawn(parent.id, "fix", "review") end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, %{id: id}}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:error, "a subagent is already running"} in results
    assert_eventually(fn -> Runs.get_run(id).status != :starting end)
    assert Repo.aggregate(from(r in Run, where: r.spawned_by_run_id == ^parent.id), :count) == 1
  end

  test "subagent completion retries a rejected close and never loses its result", ctx do
    parent = working_run(ctx)

    {:ok, child} =
      Runs.create_run(%{
        name: "fix",
        task: "review",
        cwd: ctx.cwd,
        role: "fix",
        spawned_by_run_id: parent.id
      })

    child =
      child
      |> Run.progress_changeset(%{
        status: :working,
        pane_id: "w1:p9",
        terminal_id: "term-run",
        tab_id: "w1:t2",
        started_at: DateTime.utc_now()
      })
      |> Repo.update!()

    assert {:ok, _} = Runs.submit_result(child.id, "findings", [])
    Agent.update(ctx.behavior, &Map.put(&1, "pane.close", {:error, "rejected"}))
    Runs.apply_view(with_run_pane("idle"), %{child.id => "working"})
    assert %{status: :done, result: %{"summary" => "findings"}} = Runs.get_run(child.id)
    Agent.update(ctx.behavior, &Map.delete(&1, "pane.close"))
    old = DateTime.add(DateTime.utc_now(), -30, :second)
    Repo.update_all(from(r in Run, where: r.id == ^child.id), set: [finished_at: old])
    Runs.apply_view(with_run_pane("working"), %{child.id => "working"})
    assert %{status: :finished, result: %{"summary" => "findings"}} = Runs.get_run(child.id)
  end

  test "a waiting spawner wakes when its subagent finishes", ctx do
    parent = working_run(ctx)

    {:ok, child} =
      Runs.create_run(%{
        name: "fix",
        role: "fix",
        task: "review",
        cwd: ctx.cwd,
        spawned_by_run_id: parent.id
      })

    child = child |> Run.progress_changeset(%{status: :working}) |> Repo.update!()
    waiter = Task.async(fn -> Jarvis2.Subagents.wait(child.id, parent.id, 5_000) end)
    assert {:ok, child} = Runs.submit_result(child.id, "report", [])
    Runs.transition_subagent(child, :finished, "test")
    assert {:ok, %{status: "finished", result: result}} = Task.await(waiter, 1_000)
    assert result =~ "report"
  end

  test "subagent disappearance distinguishes a reported result from a loss", ctx do
    parent = working_run(ctx)

    for {reported, expected} <- [{true, :finished}, {false, :lost}] do
      {:ok, child} =
        Runs.create_run(%{
          name: "fix",
          role: "fix",
          task: "review",
          cwd: ctx.cwd,
          spawned_by_run_id: parent.id
        })

      child =
        child
        |> Run.progress_changeset(%{
          status: :working,
          pane_id: "missing",
          terminal_id: "old",
          started_at: DateTime.add(DateTime.utc_now(), -10, :second)
        })
        |> Repo.update!()

      if reported, do: Runs.submit_result(child.id, "report", [])
      Runs.apply_view(with_run_pane("working"), %{})
      assert Runs.get_run(child.id).status == expected
    end
  end

  test "a subagent that idles without a result fails with its pane open", ctx do
    parent = working_run(ctx)

    {:ok, child} =
      Runs.create_run(%{
        name: "fix",
        role: "fix",
        task: "review",
        cwd: ctx.cwd,
        spawned_by_run_id: parent.id
      })

    child
    |> Run.progress_changeset(%{
      status: :working,
      pane_id: "w1:p10",
      terminal_id: "other",
      started_at: DateTime.utc_now()
    })
    |> Repo.update!()

    agent = %{"pane_id" => "w1:p10", "agent" => "pi", "agent_status" => "idle"}
    view = update_in(with_run_pane("idle"), [:snapshot, "agents"], &(&1 ++ [agent]))
    :ok = GenServer.call(ctx.mirror, {:put, view})
    Runs.apply_view(view, %{child.id => "working"})
    assert Runs.get_run(child.id).status == :failed
    assert {:ok, %{status: "failed"}} = Jarvis2.Subagents.wait(child.id, parent.id, 0)
    refute_receive {:request, "pane.close", _}, 50
  end

  test "failed subagents keep their pane and the spawner cascade closes it", ctx do
    parent = working_run(ctx)

    {:ok, child} =
      Runs.create_run(%{
        name: "fix",
        role: "fix",
        task: "review",
        cwd: ctx.cwd,
        spawned_by_run_id: parent.id
      })

    child =
      child
      |> Run.progress_changeset(%{
        status: :working,
        pane_id: "w1:p9",
        terminal_id: "term-run",
        tab_id: "w1:t2",
        started_at: DateTime.add(DateTime.utc_now(), -601, :second)
      })
      |> Repo.update!()

    Runs.apply_view(with_run_pane("working"), %{child.id => "working"})
    assert Runs.get_run(child.id).status == :failed
    assert_receive {:request, "pane.send_keys", %{"pane_id" => "w1:p9", "keys" => ["esc"]}}
    refute_receive {:request, "pane.close", _}, 50
    assert {:ok, _} = Runs.submit_result(parent.id, "finished", [])
    assert_receive {:request, "pane.close", %{"pane_id" => "w1:p9"}}
    assert Runs.get_run(child.id).status == :stopped
  end

  test "the implementer is identifiable before its first prompt returns", ctx do
    observer = self()
    Agent.update(ctx.behavior, &Map.put(&1, "agent.prompt", {:hold, observer}))
    {:ok, run} = Runs.create_run(%{name: "implementer", task: "work", cwd: ctx.cwd})
    launcher = Task.async(fn -> Runs.launch(run) end)
    assert_receive {:prompt_held, server}, 3_000
    assert %{run_id: id} = Jarvis2.MCP.Caller.resolve(%{"x-herdr-pane" => "w1:p9"})
    assert id == run.id
    Runs.apply_view(view(), %{})
    assert Runs.get_run(run.id).status == :starting
    send(server, :release)
    assert %{status: :working} = Task.await(launcher, 3_000)
  end

  test "a timed-out subagent must stop working before another can start", ctx do
    roles = Path.join(ctx.cwd, "roles")
    File.mkdir_p!(roles)
    File.write!(Path.join(roles, "fix.md"), "---\nname: fix\nsubagent: true\n---\nReview only.")
    config(:roles_dir, roles)
    config(:live_scenarios, [:subagents])
    parent = working_run(ctx) |> Run.progress_changeset(%{tab_id: "w1:t2"}) |> Repo.update!()

    {:ok, child} =
      Runs.create_run(%{
        name: "fix",
        role: "fix",
        task: "review",
        cwd: ctx.cwd,
        spawned_by_run_id: parent.id
      })

    child
    |> Run.progress_changeset(%{status: :failed, pane_id: "w1:p10", terminal_id: "other"})
    |> Repo.update!()

    agent = %{"pane_id" => "w1:p10", "agent" => "pi", "agent_status" => "working"}
    busy = update_in(with_run_pane("idle"), [:snapshot, "agents"], &(&1 ++ [agent]))
    :ok = GenServer.call(ctx.mirror, {:put, busy})

    assert {:error, "a subagent is already running"} =
             Jarvis2.Subagents.spawn(parent.id, "fix", "again")

    idle = put_in(busy, [:snapshot, "agents", Access.at(1), "agent_status"], "idle")
    :ok = GenServer.call(ctx.mirror, {:put, idle})
    assert {:ok, %{id: id}} = Jarvis2.Subagents.spawn(parent.id, "fix", "again")
    assert_eventually(fn -> Runs.get_run(id).status != :starting end)
  end

  test "stopping, losing or completing the spawner cleans up its child", ctx do
    for ending <- [:stop, :lost, :card_done] do
      parent = working_run(ctx) |> Run.progress_changeset(%{tab_id: "w1:t2"}) |> Repo.update!()

      {:ok, child} =
        Runs.create_run(%{
          name: "fix",
          role: "fix",
          task: "review",
          cwd: ctx.cwd,
          spawned_by_run_id: parent.id
        })

      child
      |> Run.progress_changeset(%{
        status: :working,
        pane_id: "w1:p10",
        terminal_id: "other",
        tab_id: "w1:t2",
        started_at: DateTime.utc_now()
      })
      |> Repo.update!()

      child_view = with_run_pane("idle")
      :ok = GenServer.call(ctx.mirror, {:put, child_view})

      case ending do
        :stop ->
          assert {:ok, _} = Runs.stop_run(parent)
          assert_receive {:request, "tab.close", %{"tab_id" => "w1:t2"}}

        :lost ->
          missing_parent =
            update_in(
              child_view,
              [:snapshot, "panes"],
              &Enum.reject(&1, fn pane -> pane["pane_id"] == parent.pane_id end)
            )

          :ok = GenServer.call(ctx.mirror, {:put, missing_parent})
          Runs.apply_view(missing_parent, %{})
          assert Runs.get_run(parent.id).status == :lost
          assert_receive {:request, "pane.close", %{"pane_id" => "w1:p10"}}

        :card_done ->
          {:ok, card} = Jarvis2.Kanban.create_card(%{title: "plan", cwd: ctx.cwd})

          card
          |> Ecto.Changeset.change(column: :agent, stage: :implementation, run_id: parent.id)
          |> Repo.update!()

          assert {:ok, _} = Jarvis2.Kanban.submit_deliverable(parent.id, "complete")
          assert_receive {:request, "pane.close", %{"pane_id" => "w1:p10"}}
      end

      assert Runs.get_run(child.id).status == :stopped
    end
  end

  test "a failed subagent launch retains its pane for the spawner cascade", ctx do
    parent = working_run(ctx) |> Run.progress_changeset(%{tab_id: "w1:t2"}) |> Repo.update!()

    {:ok, child} =
      Runs.create_run(%{
        name: "fix",
        role: "fix",
        task: "review",
        cwd: ctx.cwd,
        spawned_by_run_id: parent.id
      })

    Agent.update(ctx.behavior, &Map.put(&1, "agent.start", {:error, "agent_not_ready"}))

    assert %{status: :failed, pane_id: "w1:p10", tab_id: "w1:t2"} =
             Runs.launch(child, fn _ -> :ok end, "fix", {:split, parent.pane_id, parent.tab_id})

    :ok =
      GenServer.call(
        ctx.mirror,
        {:put,
         with_run_pane("idle")
         |> put_in([:snapshot, "panes", Access.at(2), "terminal_id"], "term-impl")}
      )

    assert {:ok, _} = Runs.submit_result(parent.id, "finished", [])
    assert_receive {:request, "pane.close", %{"pane_id" => "w1:p10"}}
  end

  test "subagent spawn lifetime is limited and reports reject oversized results", ctx do
    roles = Path.join(ctx.cwd, "roles")
    File.mkdir_p!(roles)
    File.write!(Path.join(roles, "fix.md"), "---\nname: fix\nsubagent: true\n---\nReview only.")
    config(:roles_dir, roles)
    config(:live_scenarios, [:subagents])
    parent = working_run(ctx) |> Run.progress_changeset(%{tab_id: "w1:t2"}) |> Repo.update!()

    for _ <- 1..3 do
      {:ok, child} =
        Runs.create_run(%{
          name: "fix",
          role: "fix",
          task: "review",
          cwd: ctx.cwd,
          spawned_by_run_id: parent.id
        })

      assert {:error, "summary exceeds 32768 bytes; shorten it"} =
               Runs.submit_result(child.id, String.duplicate("x", 32_769), [])

      child |> Run.progress_changeset(%{status: :failed}) |> Repo.update!()
    end

    assert {:error, "subagent limit reached"} = Jarvis2.Subagents.spawn(parent.id, "fix", "again")
  end

  test "subagent guard caller is isolated per spawner", %{cwd: cwd} do
    {:ok, parent} = Runs.create_run(%{name: "parent", task: "work", cwd: cwd})

    {:ok, child} =
      Runs.create_run(%{name: "fix", task: "review", cwd: cwd, spawned_by_run_id: parent.id})

    assert Launcher.caller(parent).pane == "system:ui"

    assert Launcher.caller(child) == %{
             system: "subagent",
             pane: "system:subagent:" <> parent.id,
             run_id: child.id
           }

    guard = Application.fetch_env!(:jarvis2, :execution_guard)
    assert {:ok, _, lease} = ExecutionGuard.reserve(Launcher.caller(child), guard)
    :ok = ExecutionGuard.finish(lease, :uncertain, guard)

    assert {:error, "caller execution is busy or cooling down"} =
             ExecutionGuard.reserve(Launcher.caller(child), guard)

    assert {:ok, _, lease} = ExecutionGuard.reserve(Launcher.caller(parent), guard)
    :ok = ExecutionGuard.finish(lease, :ok, guard)
  end

  test "a tab reply without a tab id still launches with legacy pane cleanup", ctx do
    pane = %{pane_id: "w1:p9", terminal_id: "term-run", workspace_id: "w1"}

    Agent.update(
      ctx.behavior,
      &Map.put(&1, "tab.create", {:reply, %{type: "tab_created", root_pane: pane}})
    )

    {:ok, run} = Runs.create_run(%{name: "demo", task: "x", cwd: ctx.cwd})
    run = Runs.launch(run)
    assert run.status == :working
    assert run.tab_id == nil
    assert {:ok, _} = Runs.stop_run(run)
    assert_receive {:request, "pane.close", %{"pane_id" => "w1:p9"}}
  end

  describe "launch/1" do
    test "starts a real run even when agent scenarios are disabled", %{cwd: cwd} do
      {:ok, run} = Runs.create_run(%{name: "demo", task: "private task", cwd: cwd})
      assert %Run{status: :working} = Runs.launch(run)
      assert_receive {:request, "tab.create", _}
      assert_receive {:request, "agent.start", _}
      assert_receive {:request, "agent.prompt", _}
      refute inspect(Journal.recent()) =~ "private task"
    end

    test "in live mode creates a tab, starts Pi with the model and delivers the task",
         ctx do
      live!()
      config(:skills_dir, ctx.cwd)
      config(:pi_extension, Path.join(ctx.cwd, "jarvis2-run.js"))
      {:ok, run} = Runs.create_run(%{name: "demo", task: "write the report", cwd: ctx.cwd})
      Phoenix.PubSub.subscribe(Jarvis2.PubSub, Runs.topic())

      assert %Run{status: :working, pane_id: "w1:p9", terminal_id: "term-run"} =
               launched = Runs.launch(run)

      assert launched.agent_name == "run-" <> String.slice(run.id, 0, 8)
      assert_receive {:run, %Run{status: :working}}

      assert_receive {:request, "tab.create", split}
      assert split["workspace_id"] == "w1"
      assert split["label"] == "write the report"
      refute_receive {:request, "pane.split", _}, 50
      assert split["cwd"] == ctx.cwd
      assert split["env"]["JARVIS2_RUN_ID"] == run.id
      assert Enum.sort(Map.keys(split["env"])) == ["JARVIS2_MCP_URL", "JARVIS2_RUN_ID"]
      assert split["env"]["JARVIS2_MCP_URL"] =~ ~r{^http://127\.0\.0\.1:\d+/mcp$}
      assert split["focus"] == false

      assert_receive {:request, "agent.start", start}
      assert start["pane_id"] == "w1:p9"
      assert start["kind"] == "pi"

      assert start["args"] ==
               ~w(--provider openrouter --model openai/gpt-6-luna --thinking low --extension) ++
                 [Path.join(ctx.cwd, "jarvis2-run.js"), "--no-skills", "--skill", ctx.cwd]

      assert_receive {:request, "agent.prompt", %{"target" => "w1:p9", "text" => text}}
      assert text == "write the report"
      assert byte_size(text) <= 65_536

      events = Journal.recent(run_id: run.id)
      assert %{outcome: :ok} = Enum.find(events, &(&1.type == "run.start"))
      assert %{outcome: :ok, source: :ui} = Enum.find(events, &(&1.type == "fleet.prompt"))
      refute inspect(events) =~ "write the report"
    end

    test "a rejected tab fails the run without starting an agent", ctx do
      live!()
      Agent.update(ctx.behavior, &Map.put(&1, "tab.create", {:error, "invalid_request"}))
      {:ok, run} = Runs.create_run(%{name: "demo", task: "t", cwd: ctx.cwd})

      assert %Run{status: :failed, pane_id: nil, result: %{"error" => error}} = Runs.launch(run)
      assert error =~ "rejected the new tab"
      refute_receive {:request, "agent.start", _}, 100
    end

    test "an uncertain tab creation warns before retry", ctx do
      Agent.update(ctx.behavior, &Map.put(&1, "tab.create", {:error, "timeout"}))
      {:ok, run} = Runs.create_run(%{name: "demo", task: "t", cwd: ctx.cwd})
      assert %Run{status: :failed, pane_id: nil, result: %{"error" => error}} = Runs.launch(run)
      assert error =~ "tab may have been created"
      refute_receive {:request, "agent.start", _}, 100
    end

    test "launch stores resolved workspace and checkout and closes only the fresh tab after creation",
         ctx do
      checkout = Path.join(ctx.cwd, "checkout")
      File.mkdir_p!(checkout)

      Agent.update(
        ctx.behavior,
        &Map.merge(&1, %{
          "worktree.list" =>
            {:reply,
             %{
               worktrees: [
                 %{path: ctx.cwd, is_linked_worktree: false, open_workspace_id: "w1"},
                 %{path: checkout, branch: "feature", is_linked_worktree: true}
               ]
             }},
          "worktree.open" =>
            {:reply,
             %{
               workspace: %{workspace_id: "w1"},
               tab: %{tab_id: "w1:t8"},
               worktree: %{path: checkout}
             }}
        })
      )

      {:ok, run} =
        Runs.create_run(%{name: "test", task: "test", cwd: ctx.cwd, worktree: "feature"})

      run = Runs.launch(run)
      assert run.status == :working
      assert %{workspace_id: "w1", cwd: ^checkout, worktree: "feature"} = Runs.get_run(run.id)
      assert_receive {:request, "worktree.open", %{"workspace_id" => "w1", "branch" => "feature"}}
      assert_receive {:request, "tab.create", %{"workspace_id" => "w1", "cwd" => ^checkout}}
      assert_receive {:request, "tab.close", %{"tab_id" => "w1:t8"}}
    end

    test "close failure is ignored and rejected worktrees do not create a tab", ctx do
      Agent.update(
        ctx.behavior,
        &Map.merge(&1, %{
          "worktree.list" =>
            {:reply, %{worktrees: [%{path: ctx.cwd, is_linked_worktree: false}]}},
          "tab.close" => {:error, "invalid_request"}
        })
      )

      {:ok, run} = Runs.create_run(%{name: "test", task: "test", cwd: ctx.cwd})
      assert Runs.launch(run).status == :working
      assert_receive {:request, "tab.create", _}
      assert_receive {:request, "tab.close", %{"tab_id" => "w1:t1"}}
      Agent.update(ctx.behavior, &Map.put(&1, "worktree.open", {:error, "worktree_busy"}))
      {:ok, run} = Runs.create_run(%{name: "test", task: "test", cwd: ctx.cwd})
      assert %{status: :failed, result: %{"error" => message}} = Runs.launch(run)
      assert message =~ "worktree_busy"
      refute_receive {:request, "tab.create", _}, 50
    end

    test "split in a different workspace falls back to a new tab", ctx do
      :ok = GenServer.call(ctx.mirror, {:put, with_run_pane("idle")})

      Agent.update(
        ctx.behavior,
        &Map.put(
          &1,
          "worktree.list",
          {:reply,
           %{worktrees: [%{path: ctx.cwd, is_linked_worktree: false, open_workspace_id: "w2"}]}}
        )
      )

      {:ok, run} = Runs.create_run(%{name: "test", task: "test", cwd: ctx.cwd})
      _ = Runs.launch(run, fn _ -> :ok end, nil, {:split, "w1:p9", "w1:t2"})
      assert_receive {:request, "tab.create", %{"workspace_id" => "w2"}}
      refute_receive {:request, "pane.split", _}, 50
    end

    test "an unconfirmed task is reported but the run keeps its pane", ctx do
      live!()
      Agent.update(ctx.behavior, &Map.put(&1, "agent.prompt", {:error, "agent_blocked"}))
      {:ok, run} = Runs.create_run(%{name: "demo", task: "t", cwd: ctx.cwd})

      assert %Run{status: :working, pane_id: "w1:p9"} = Runs.launch(run)

      assert %{outcome: :error} =
               Enum.find(Journal.recent(run_id: run.id), &(&1.type == "run.start"))
    end

    test "only a starting run is launched", ctx do
      {:ok, run} = Runs.create_run(%{name: "demo", task: "t", cwd: ctx.cwd})
      done = Runs.launch(run)
      assert Runs.launch(done) == done
    end

    test "Launcher.availability explains why a live start is impossible", ctx do
      assert {:error, "Herdr is not connected" <> _} = Launcher.availability(nil)

      assert {:error, "Herdr is not connected" <> _} =
               Launcher.availability(%{stale: true, snapshot: nil})

      assert :ok = Launcher.availability(view())

      assert :ok = Launcher.availability(put_in(view(), [:snapshot, "workspaces"], []))

      _ = ctx
    end
  end

  describe "stop_run/1 and prompt_run/2" do
    setup ctx do
      live!()
      %{run: working_run(ctx)}
    end

    test "stop closes only the pane that was created for the run", %{run: run, mirror: mirror} do
      assert {:ok, %Run{status: :stopped, finished_at: %DateTime{}}} = Runs.stop_run(run)
      assert_receive {:request, "pane.close", %{"pane_id" => "w1:p9"}}

      # A reused pane id with a different terminal must be left alone.
      other = working_run(%{cwd: run.cwd, mirror: mirror})
      :ok = GenServer.call(mirror, {:put, with_run_pane("idle", terminal: "someone-else")})
      assert {:ok, %Run{status: :stopped}} = Runs.stop_run(other)
      refute_receive {:request, "pane.close", _}, 100
    end

    test "stop refuses to act on stale Herdr state and keeps the run active", %{
      run: run,
      mirror: mirror
    } do
      :ok = GenServer.call(mirror, {:put, %{view() | stale: true}})
      assert {:error, "Herdr is not connected" <> _} = Runs.stop_run(run)
      assert Runs.get_run(run.id).status == :working
      refute_receive {:request, "pane.close", _}, 100
    end

    test "prompt reaches an idle agent and is refused while it is busy", %{
      run: run,
      mirror: mirror
    } do
      assert {:ok, _} = Runs.prompt_run(run, "  next step  ")
      assert_receive {:request, "agent.prompt", %{"target" => "w1:p9", "text" => "next step"}}

      :ok = GenServer.call(mirror, {:put, with_run_pane("working")})
      assert {:error, "The agent is busy" <> _} = Runs.prompt_run(run, "again")
      assert {:error, "Write something" <> _} = Runs.prompt_run(run, "   ")

      assert {:error, "The prompt is invalid or too long" <> _} =
               Runs.prompt_run(run, String.duplicate("x", 65_537))
    end

    test "long follow-ups retain multibyte and escaped text while controls are rejected", %{
      run: run
    } do
      text = String.duplicate("é\"", 4_000)
      assert {:ok, _} = Runs.prompt_run(run, text)
      assert_receive {:request, "agent.prompt", %{"text" => ^text}}
      assert {:error, "The prompt is invalid" <> _} = Runs.prompt_run(run, "bad\u0001text")
      assert {:error, "The prompt is invalid" <> _} = Runs.prompt_run(run, "bad\r")
      assert {:error, "The prompt is invalid" <> _} = Runs.prompt_run(run, <<255>>)
    end

    test "can wait for a busy agent to become idle", %{run: run, mirror: mirror} do
      :ok = GenServer.call(mirror, {:put, with_run_pane("working")})

      Task.start(fn ->
        Process.sleep(350)
        GenServer.call(mirror, {:put, with_run_pane("idle")})
      end)

      assert {:ok, _} = Runs.prompt_run(run, "follow-up", wait_ms: 2_000)
      assert_receive {:request, "agent.prompt", %{"text" => "follow-up"}}
    end

    test "does not deliver a waiting prompt to a replaced terminal", %{run: run, mirror: mirror} do
      :ok = GenServer.call(mirror, {:put, with_run_pane("working")})
      waiting = Task.async(fn -> Runs.prompt_run(run, "private answer", wait_ms: 2_000) end)
      Process.sleep(300)
      :ok = GenServer.call(mirror, {:put, with_run_pane("idle", terminal: "replacement")})
      assert {:error, _} = Task.await(waiting, 3_000)
      refute_receive {:request, "agent.prompt", _}, 100
    end

    test "a finished run cannot be prompted or stopped", %{run: run} do
      {:ok, stopped} = Runs.stop_run(run)
      assert {:error, "The run is not active."} = Runs.prompt_run(stopped, "hello")
      assert {:error, "The run is not active."} = Runs.stop_run(stopped)
    end
  end

  describe "kanban integration" do
    test "a scratch card starts only one run", ctx do
      title = String.duplicate("x", 80)
      {:ok, card} = Jarvis2.Kanban.create_card(%{title: title, cwd: ctx.cwd})

      results =
        1..2
        |> Task.async_stream(fn _ -> Jarvis2.Kanban.move(card, :agent) end, max_concurrency: 2)
        |> Enum.map(fn {:ok, value} -> value end)

      assert [{:ok, moved}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert [{:error, _}] = Enum.filter(results, &match?({:error, _}, &1))
      assert moved.column == :agent
      assert length(Repo.all(Run)) == 1
      assert_receive {:request, "tab.create", %{"label" => label}}, 3_000
      assert label == String.slice(title, 0, 32)
      assert_receive {:request, "agent.start", _}, 3_000
      assert_receive {:request, "agent.prompt", %{"text" => text}}, 3_000
      assert text =~ "requirements engineer"
      assert text =~ "Card: #{title}"
      refute text =~ "ask_human"
      refute text =~ "request_approval"
      refute text =~ "submit_result"
      assert_eventually(fn -> Journal.count(type: "run.start", run_id: moved.run_id) > 0 end)
      assert Runs.get_run(moved.run_id).status == :working
    end

    test "archive and restore retains session and history without duplicate deliveries", ctx do
      alias Jarvis2.Kanban
      run = working_run(ctx)
      session = Ecto.UUID.generate()
      run = run |> Ecto.Changeset.change(session_id: session, tab_id: "w1:t2") |> Repo.update!()
      {:ok, card} = Kanban.create_card(%{title: "Archive", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

      {:ok, round} =
        Kanban.ask_questions(run.id, [%{title: "Decision", body: "Choose", recommended: "yes"}])

      {:ok, round} =
        Kanban.save_draft(round, %{"Q1" => %{"kind" => "recommended", "text" => "yes"}})

      :ok = GenServer.call(ctx.mirror, {:put, with_run_pane("working")})
      config(:kanban_delivery_wait_ms, 200)
      {:ok, _} = Kanban.submit_answers(round)
      assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) > 0 end)
      assert Kanban.get_round(round.id).delivered_at == nil
      {:ok, _} = Kanban.submit_deliverable(run.id, "previous result")
      assert {:ok, archived} = Kanban.move(Kanban.get_card(card.id), :archive)
      assert archived.run_id == run.id
      assert archived.deliverable == "previous result"
      assert Runs.get_run(run.id).status == :stopped
      assert_receive {:request, "tab.close", %{"tab_id" => "w1:t2"}}
      assert Runs.get_active_by_pane(run.pane_id) == nil

      assert {:error, _} =
               Kanban.ask_questions(run.id, [%{title: "x", body: "y", recommended: "z"}])

      assert {:error, _} = Kanban.submit_deliverable(run.id, "bad")

      for target <- [:scratch, :done, :awaiting_user],
          do: assert({:error, _} = Kanban.move(archived, target))

      assert {:error, _} = Kanban.reopen(archived, " ")
      {:ok, restored} = Kanban.reopen(archived, "Revise it")
      refute restored.run_id == run.id
      new_run = Runs.get_run(restored.run_id)
      assert new_run.session_id == session
      assert new_run.task =~ "Restored from archive"
      assert new_run.task =~ "Revise it"
      assert new_run.task =~ "Decision"
      assert %DateTime{} = Kanban.get_round(round.id).delivered_at
      assert_receive {:request, "agent.start", %{"args" => args}}, 3_000
      assert Enum.take(args, -2) == ["--session-id", session]
      assert_receive {:request, "agent.prompt", %{"text" => text}}, 8_000
      assert text =~ "Revise it"
      assert_eventually(fn -> Runs.get_run(restored.run_id).status == :working end)
    end

    test "new scratch agents get new sessions and legacy archive restores cold", ctx do
      alias Jarvis2.Kanban
      {:ok, card} = Kanban.create_card(%{title: "Scratch", cwd: ctx.cwd})
      {:ok, first} = Kanban.move(card, :agent)
      assert_eventually(fn -> Runs.get_run(first.run_id).status == :working end, 500)
      first_run = Runs.get_run(first.run_id)
      assert {:ok, _} = Ecto.UUID.cast(first_run.session_id)
      {:ok, scratch} = Kanban.move(Kanban.get_card(card.id), :scratch)
      {:ok, second} = Kanban.move(scratch, :agent)
      assert_eventually(fn -> Runs.get_run(second.run_id).status == :working end, 500)
      second_run = Runs.get_run(second.run_id)
      refute second_run.session_id == first_run.session_id
      second_run |> Ecto.Changeset.change(session_id: nil) |> Repo.update!()
      {:ok, archived} = Kanban.move(Kanban.get_card(card.id), :archive)
      {:ok, restored} = Kanban.reopen(archived, "retry")
      new_run = Runs.get_run(restored.run_id)
      assert {:ok, _} = Ecto.UUID.cast(new_run.session_id)
      assert new_run.task =~ "Restored from archive"
      assert_eventually(fn -> Runs.get_run(restored.run_id).status == :working end, 500)
    end

    test "a failed restore keeps its session for a later retry", ctx do
      alias Jarvis2.Kanban
      session = Ecto.UUID.generate()

      run =
        working_run(ctx)
        |> Ecto.Changeset.change(session_id: session, tab_id: "w1:t2")
        |> Repo.update!()

      {:ok, card} = Kanban.create_card(%{title: "Retry", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
      {:ok, archived} = Kanban.move(Kanban.get_card(card.id), :archive)
      Agent.update(ctx.behavior, &Map.put(&1, "tab.create", {:error, "invalid_request"}))
      {:ok, attempted} = Kanban.reopen(archived, "First reason")
      assert_eventually(fn -> Runs.get_run(attempted.run_id).status == :failed end)
      assert Runs.get_run(attempted.run_id).session_id == session
      {:ok, archived_again} = Kanban.move(Kanban.get_card(card.id), :archive)
      Agent.update(ctx.behavior, &Map.delete(&1, "tab.create"))
      # A failed launch puts the execution guard into a 60-second uncertainty cooldown.
      guard = start_supervised!({ExecutionGuard, [name: nil]}, id: :retry_guard)
      config(:execution_guard, guard)
      {:ok, retry} = Kanban.reopen(archived_again, "Second reason")
      assert Runs.get_run(retry.run_id).session_id == session
      assert_eventually(fn -> Runs.get_run(retry.run_id).status == :working end, 1_500)
    end

    test "a non-Pi archived run starts a fresh Pi session", ctx do
      alias Jarvis2.Kanban
      old_id = Ecto.UUID.generate()

      run =
        working_run(ctx)
        |> Ecto.Changeset.change(kind: "codex", session_id: old_id)
        |> Repo.update!()

      {:ok, card} = Kanban.create_card(%{title: "Other agent", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
      {:ok, archived} = Kanban.move(Kanban.get_card(card.id), :archive)
      {:ok, restored} = Kanban.reopen(archived, "Continue")
      assert Runs.get_run(restored.run_id).session_id != old_id
      assert_eventually(fn -> Runs.get_run(restored.run_id).status == :working end, 500)
    end

    test "archive cancels an open round and refuses unavailable or failed closes", ctx do
      alias Jarvis2.Kanban
      run = working_run(ctx) |> Ecto.Changeset.change(tab_id: "w1:t2") |> Repo.update!()
      {:ok, card} = Kanban.create_card(%{title: "Working", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

      {:ok, round} =
        Kanban.ask_questions(run.id, [%{title: "Q", body: "Body", recommended: "yes"}])

      :ok = GenServer.call(ctx.mirror, {:put, %{view() | stale: true}})
      assert {:error, _} = Kanban.move(Kanban.get_card(card.id), :archive)
      assert Kanban.get_card(card.id).column == :awaiting_user
      assert Kanban.get_round(round.id).status == :open
      :ok = GenServer.call(ctx.mirror, {:put, with_run_pane("idle")})
      Agent.update(ctx.behavior, &Map.put(&1, "tab.close", {:error, "failed"}))
      assert {:error, _} = Kanban.move(Kanban.get_card(card.id), :archive)
      assert Runs.get_run(run.id).status == :working
      Agent.update(ctx.behavior, &Map.delete(&1, "tab.close"))
      assert {:ok, archived} = Kanban.move(Kanban.get_card(card.id), :archive)
      assert archived.column == :archive
      assert Kanban.get_round(round.id).status == :cancelled
      :ok = GenServer.call(ctx.mirror, {:put, %{view() | stale: true}})
      assert {:error, _} = Kanban.reopen(archived, "try again")
      assert Kanban.get_card(card.id).column == :archive
    end

    test "slides reopen and restore provide the saved deck to the agent", ctx do
      run = working_run(ctx)
      {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Deck", kind: :slides, cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
      html = "<!doctype html><html><head></head><body>Private deck</body></html>"
      {:ok, _} = Jarvis2.Kanban.submit_deliverable(run.id, html)
      path = Jarvis2.Kanban.Slides.path(card.id)
      {:ok, reopened} = Jarvis2.Kanban.reopen(Jarvis2.Kanban.get_card(card.id), "Revise")
      assert reopened.run_id == run.id
      assert File.read!(path) == html
      assert_receive {:request, "agent.prompt", %{"text" => text}}, 3_000
      assert text =~ path
      refute text =~ html
      assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) > 0 end)
      {:ok, _} = Jarvis2.Kanban.submit_deliverable(run.id, html)
      {:ok, archived} = Jarvis2.Kanban.move(Jarvis2.Kanban.get_card(card.id), :archive)
      {:ok, restored} = Jarvis2.Kanban.reopen(archived, "Restore")
      assert restored.run.task =~ path
      refute restored.run.task =~ html
      assert File.read!(path) == html
      assert_eventually(fn -> Runs.get_run(restored.run_id).status == :working end, 500)
    end

    test "slides reopen rolls back if its transient deck cannot be written", ctx do
      run = working_run(ctx)
      {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Deck", kind: :slides, cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
      html = "<!doctype html><html><head></head><body>Deck</body></html>"
      {:ok, _} = Jarvis2.Kanban.submit_deliverable(run.id, html)
      path = Jarvis2.Kanban.Slides.path(card.id)
      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(path) end)

      assert {:error, "Could not save" <> _} =
               Jarvis2.Kanban.reopen(Jarvis2.Kanban.get_card(card.id), "Revise")

      assert Jarvis2.Kanban.get_card(card.id).column == :done
      refute_receive {:request, "agent.prompt", _}, 100
    end

    test "reopen delivers feedback to the same pane", ctx do
      run = working_run(ctx)
      {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Plan this", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
      assert {:ok, _} = Jarvis2.Kanban.report_skill(run.id, "planning", "Define scope")
      assert {:ok, _} = Jarvis2.Kanban.submit_deliverable(run.id, "The plan")
      card = Jarvis2.Kanban.get_card(card.id)
      assert {:ok, reopened} = Jarvis2.Kanban.reopen(card, "Add alternatives")
      assert [%{name: "planning"}] = Jarvis2.Kanban.get_card(card.id).skill_uses
      assert reopened.run_id == run.id
      assert_receive {:request, "agent.prompt", %{"text" => text}}, 3_000
      assert text =~ "Add alternatives"
      assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) > 0 end)
      assert length(Repo.all(Run)) == 1
    end

    test "a dead run is replaced with the plan, latest answers and reopen feedback", ctx do
      run = working_run(ctx)
      {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Plan this", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

      {:ok, round} =
        Jarvis2.Kanban.ask_questions(run.id, [
          %{title: "Decision", body: "Choose", recommended: "yes"}
        ])

      {:ok, round} =
        Jarvis2.Kanban.save_draft(round, %{"Q1" => %{"kind" => "recommended", "text" => "yes"}})

      {:ok, _} = Jarvis2.Kanban.submit_answers(round)
      assert_receive {:request, "agent.prompt", _}, 3_000
      assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) > 0 end)
      {:ok, _} = Jarvis2.Kanban.submit_deliverable(run.id, "Previous finished plan")
      run |> Run.progress_changeset(%{status: :lost}) |> Repo.update!()
      {:ok, reopened} = Jarvis2.Kanban.reopen(Jarvis2.Kanban.get_card(card.id), "Add more")
      refute reopened.run_id == run.id
      assert_receive {:request, "agent.start", _}, 3_000
      assert_receive {:request, "agent.prompt", %{"text" => text}}, 8_000
      assert text =~ "Decision"
      assert text =~ "Previous finished plan"
      assert text =~ "Add more"

      assert_eventually(fn ->
        Journal.count(type: "kanban.delivery", run_id: reopened.run_id) > 0
      end)

      assert Runs.get_run(reopened.run_id).status == :working
    end

    test "moving to scratch stops the run and cancels its open round", ctx do
      run = working_run(ctx)
      {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Plan this", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

      {:ok, round} =
        Jarvis2.Kanban.ask_questions(run.id, [
          %{title: "Which?", body: "Choose", recommended: "yes"}
        ])

      assert {:ok, _} = Jarvis2.Kanban.move(Jarvis2.Kanban.get_card(card.id), :scratch)
      assert Runs.get_run(run.id).status == :stopped
      assert Jarvis2.Kanban.get_round(round.id).status == :cancelled
      assert_receive {:request, "pane.close", _}
    end

    test "failed delivery remains pending and can be retried", ctx do
      config(:kanban_delivery_wait_ms, 300)
      run = working_run(ctx)
      {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Plan this", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

      {:ok, round} =
        Jarvis2.Kanban.ask_questions(run.id, [
          %{title: "Which?", body: "Choose", recommended: "yes"}
        ])

      {:ok, round} =
        Jarvis2.Kanban.save_draft(round, %{"Q1" => %{"kind" => "recommended", "text" => "yes"}})

      :ok = GenServer.call(ctx.mirror, {:put, with_run_pane("working")})
      {:ok, _} = Jarvis2.Kanban.submit_answers(round)
      assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) == 1 end)
      assert Jarvis2.Kanban.get_round(round.id).delivered_at == nil
      :ok = GenServer.call(ctx.mirror, {:put, with_run_pane("idle")})
      assert {:ok, _} = Jarvis2.Kanban.retry_delivery(Jarvis2.Kanban.get_card(card.id))
      assert_receive {:request, "agent.prompt", _}, 3_000
      assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) == 2 end)
      assert %DateTime{} = Jarvis2.Kanban.get_round(round.id).delivered_at
    end

    test "answers wait for the agent to become idle", ctx do
      run = working_run(ctx)
      {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Plan this", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

      {:ok, round} =
        Jarvis2.Kanban.ask_questions(run.id, [
          %{title: "Which?", body: "Choose", recommended: "yes"}
        ])

      {:ok, round} =
        Jarvis2.Kanban.save_draft(round, %{"Q1" => %{"kind" => "recommended", "text" => "yes"}})

      :ok = GenServer.call(ctx.mirror, {:put, with_run_pane("working")})
      {:ok, _} = Jarvis2.Kanban.submit_answers(round)
      refute_receive {:request, "agent.prompt", _}, 200
      :ok = GenServer.call(ctx.mirror, {:put, with_run_pane("idle")})
      assert_receive {:request, "agent.prompt", %{"text" => text}}, 3_000
      assert text =~ "accepted your recommendation: yes"
      assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) > 0 end)
    end
  end

  describe "apply_view/2" do
    setup ctx do
      live!()
      {:ok, run} = Runs.create_run(%{name: "demo", task: "t", cwd: ctx.cwd})
      %{run: Runs.launch(run)}
    end

    test "follows the agent: working, blocked, back to working and done when idle", %{run: run} do
      seen = %{}
      status = fn -> Runs.get_run(run.id).status end

      seen = Runs.apply_view(with_run_pane("idle"), seen)
      assert status.() == :working

      seen = Runs.apply_view(with_run_pane("working"), seen)
      seen = Runs.apply_view(with_run_pane("blocked"), seen)
      assert status.() == :blocked

      seen = Runs.apply_view(with_run_pane("working"), seen)
      assert status.() == :working

      seen = Runs.apply_view(with_run_pane("idle"), seen)
      assert status.() == :done

      # A follow-up prompt reactivates the run.
      _ = Runs.apply_view(with_run_pane("working"), seen)
      assert status.() == :working
    end

    test "marks a run lost when its pane is gone or was replaced", %{run: run} do
      Runs.apply_view(view(), %{})
      assert %{status: :lost, finished_at: %DateTime{}} = Runs.get_run(run.id)
    end

    test "treats a pane id reused by another terminal as lost", %{run: run} do
      Runs.apply_view(with_run_pane("idle", terminal: "other"), %{})
      assert Runs.get_run(run.id).status == :lost
    end

    test "ignores stale views", %{run: run} do
      Runs.apply_view(%{view() | stale: true}, %{})
      assert Runs.get_run(run.id).status == :working
    end

    test "fails a launch that never produced a pane", %{cwd: cwd} do
      {:ok, run} = Runs.create_run(%{name: "x", task: "t", cwd: cwd})
      old = DateTime.add(DateTime.utc_now(), -300, :second)
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [inserted_at: old])

      Runs.apply_view(view(), %{})
      assert %{status: :failed, result: %{"error" => "launch interrupted"}} = Runs.get_run(run.id)
    end
  end

  describe "run_mix/3" do
    setup ctx do
      fake = Path.join(ctx.cwd, "fake-mix")
      File.write!(fake, "#!/bin/sh\necho \"mix $@ ran\"\nexit ${FAKE_MIX_EXIT:-0}\n")
      File.chmod!(fake, 0o700)
      config(:mix_project_dir, ctx.cwd)
      config(:mix_executable, fake)
      :ok
    end

    test "records a passing Mix job as a finished run with its output", ctx do
      Phoenix.PubSub.subscribe(Jarvis2.PubSub, Runs.topic())
      assert {:ok, %{exit_status: 0, output: "mix test ran\n"}} = Runs.run_mix("test", nil)

      assert [%Run{kind: "mix", name: "mix test", status: :done} = run] = Repo.all(Run)
      assert run.cwd == ctx.cwd
      assert run.result["exit_status"] == 0
      assert run.result["output"] == "mix test ran\n"
      assert %DateTime{} = run.finished_at
      assert_receive {:run, %Run{status: :working, kind: "mix"}}
      assert_receive {:run, %Run{status: :done}}

      events = Journal.recent(run_id: run.id)
      assert Enum.map(events, & &1.type) == ["run.created", "run.mix"]
      assert %{outcome: :ok, payload: %{"exit_status" => 0}} = List.last(events)
    end

    test "a failing job fails the run and links it to the asking agent run", ctx do
      System.put_env("FAKE_MIX_EXIT", "2")
      on_exit(fn -> System.delete_env("FAKE_MIX_EXIT") end)
      {:ok, parent} = Runs.create_run(%{name: "agent", task: "t", cwd: ctx.cwd})

      assert {:ok, %{exit_status: 2}} = Runs.run_mix("compile", nil, parent_run_id: parent.id)
      [mix_run] = Repo.all(from r in Run, where: r.status == :failed)
      assert %Run{kind: "mix", parent_run_id: parent_id} = mix_run
      assert parent_id == parent.id
      assert %{outcome: :error} = List.last(Journal.recent(run_id: mix_run.id))
    end

    test "disallowed tasks and projects never create a run", ctx do
      assert {:error, "Mix task is not allowed"} = Runs.run_mix("deps.get", nil)
      assert Repo.all(Run) == []

      assert {:error, "project must be the configured trusted project"} =
               Runs.run_mix("test", Path.join(ctx.cwd, "elsewhere"))

      assert [%Run{status: :failed, result: %{"error" => "project" <> _}}] = Repo.all(Run)
    end

    test "Mix runs cannot be stopped and are failed if the server died mid-run", ctx do
      {:ok, _} = Runs.run_mix("test", nil)
      [done] = Repo.all(Run)
      assert {:error, "Mix runs finish on their own."} = Runs.stop_run(done)

      {:ok, orphan} =
        %Run{}
        |> Run.mix_changeset(%{task: "test", cwd: ctx.cwd})
        |> Repo.insert()

      old = DateTime.add(DateTime.utc_now(), -600, :second)
      Repo.update_all(from(r in Run, where: r.id == ^orphan.id), set: [inserted_at: old])
      Runs.apply_view(view(), %{})
      assert %{status: :failed, result: %{"error" => "interrupted"}} = Runs.get_run(orphan.id)
    end
  end

  test "the monitor applies mirror updates from the configured mirror only", %{
    cwd: cwd,
    mirror: mirror
  } do
    live!()
    {:ok, run} = Runs.create_run(%{name: "demo", task: "t", cwd: cwd})
    run = Runs.launch(run)
    start_supervised!({Monitor, [name: nil]})
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "run:" <> run.id)

    stranger = spawn(fn -> Process.sleep(:infinity) end)
    publish(stranger, view())
    refute_receive {:run, _}, 100

    publish(mirror, view())
    assert_receive {:run, %Run{status: :lost}}
  end

  # A run that is already up, so tests of later steps do not depend on the launch sequence.
  defp working_run(%{cwd: cwd, mirror: mirror}) do
    {:ok, run} = Runs.create_run(%{name: "up", task: "t", cwd: cwd})

    {:ok, run} =
      run
      |> Run.progress_changeset(%{
        status: :working,
        pane_id: "w1:p9",
        terminal_id: "term-run",
        agent_name: "run-up"
      })
      |> Repo.update()

    :ok = GenServer.call(mirror, {:put, with_run_pane("idle")})
    run
  end

  defp publish(source, view) do
    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "mirror:updated",
      {:jarvis2, "mirror:updated", %{source: source, view: view}}
    )
  end

  defp live! do
    config(:live_scenarios, [:agent_spawn, :agent_prompt])
  end

  defp respond(%{"method" => method}, _mirror, behavior) when is_map_key(behavior, method) do
    case behavior[method] do
      {:error, code} ->
        {:reply, %{error: %{code: code, message: "simulated"}}}

      {:reply, result} ->
        {:reply, %{result: result}}

      {:hold, observer} ->
        send(observer, {:prompt_held, self()})

        receive do
          :release -> {:reply, %{result: %{type: "agent_prompt", submitted: true}}}
        after
          3_000 -> {:reply, %{error: %{code: "timeout", message: "test timeout"}}}
        end
    end
  end

  defp respond(%{"method" => "worktree.list", "params" => %{"cwd" => cwd}}, _mirror, _) do
    {:reply,
     %{
       result: %{
         type: "worktree_list",
         worktrees: [
           %{path: cwd, branch: "main", is_linked_worktree: false, open_workspace_id: "w1"}
         ]
       }
     }}
  end

  defp respond(%{"method" => "workspace.create"}, _mirror, _) do
    pane = %{pane_id: "w1:p1", terminal_id: "term-anchor", workspace_id: "w1", tab_id: "w1:t1"}

    {:reply,
     %{
       result: %{
         type: "workspace_created",
         workspace: %{workspace_id: "w1"},
         tab: %{tab_id: "w1:t1"},
         root_pane: pane
       }
     }}
  end

  defp respond(%{"method" => "worktree.open", "params" => params}, _mirror, _) do
    {:reply,
     %{
       result: %{
         workspace: %{workspace_id: "w1"},
         tab: %{tab_id: "w1:t1"},
         worktree: %{path: params["path"]}
       }
     }}
  end

  defp respond(%{"method" => "tab.create"}, _mirror, _) do
    pane = %{pane_id: "w1:p9", terminal_id: "term-run", workspace_id: "w1", tab_id: "w1:t2"}
    {:reply, %{result: %{type: "tab_created", tab: %{tab_id: "w1:t2"}, root_pane: pane}}}
  end

  defp respond(%{"method" => "pane.split", "params" => params}, _mirror, _) do
    pane = %{pane_id: "w1:p10", terminal_id: "term-impl", workspace_id: "w1", tab_id: "w1:t2"}
    if params["target_pane_id"] != "w1:p9", do: raise("unexpected split target")
    {:reply, %{result: %{type: "pane_info", pane: pane}}}
  end

  defp respond(%{"method" => "pane.process_info", "params" => params}, _mirror, _) do
    info = %{
      pane_id: params["pane_id"],
      shell_pid: 7,
      foreground_process_group_id: 7,
      foreground_processes: [%{pid: 7}]
    }

    {:reply, %{result: %{type: "pane_process_info", process_info: info}}}
  end

  defp respond(%{"method" => "agent.start", "params" => params}, mirror, _) do
    view = with_run_pane("idle")

    view =
      if params["pane_id"] == "w1:p10" do
        update_in(view, [:snapshot, "agents"], fn agents ->
          agents ++
            [
              %{
                "pane_id" => "w1:p10",
                "terminal_id" => "other",
                "workspace_id" => "w1",
                "tab_id" => "w1:t2",
                "agent" => "pi",
                "agent_status" => "idle",
                "interactive_ready" => true
              }
            ]
        end)
        |> put_in([:snapshot, "panes", Access.at(2), "terminal_id"], "term-impl")
        |> put_in([:snapshot, "agents", Access.at(1), "terminal_id"], "term-impl")
      else
        view
      end

    :ok = GenServer.call(mirror, {:put, view})
    agent = %{pane_id: params["pane_id"], name: params["name"], agent: params["kind"]}
    {:reply, %{result: %{type: "agent_started", agent: agent}}}
  end

  defp respond(%{"method" => "agent.prompt"}, _mirror, _),
    do: {:reply, %{result: %{type: "agent_prompt", submitted: true}}}

  defp respond(%{"method" => "tab.close"}, mirror, _) do
    :ok = GenServer.call(mirror, {:put, view()})
    {:reply, %{result: %{type: "ok"}}}
  end

  defp respond(%{"method" => "pane.rename"}, _mirror, _), do: {:reply, %{result: %{type: "ok"}}}

  defp respond(%{"method" => "pane.report_metadata"}, _mirror, _),
    do: {:reply, %{result: %{type: "ok"}}}

  defp respond(%{"method" => "pane.close"}, _mirror, _), do: {:reply, %{result: %{type: "ok"}}}

  defp respond(%{"method" => "pane.send_keys"}, _mirror, _),
    do: {:reply, %{result: %{type: "ok"}}}

  defp view do
    %{
      stale: false,
      worktrees: %{},
      worktree_errors: %{},
      layout_diff: nil,
      snapshot: %{
        "workspaces" => [%{"workspace_id" => "w1", "label" => "jarvis2"}],
        "tabs" => [%{"workspace_id" => "w1", "tab_id" => "w1:t1"}],
        "panes" => [
          %{
            "pane_id" => "w1:p1",
            "workspace_id" => "w1",
            "tab_id" => "w1:t1",
            "terminal_id" => "term-anchor"
          }
        ],
        "agents" => [],
        "layouts" => [],
        "focused_pane_id" => "w1:p1"
      }
    }
  end

  defp with_run_pane(status, opts \\ []) do
    terminal = Keyword.get(opts, :terminal, "term-run")
    base = view()

    pane = %{
      "pane_id" => "w1:p9",
      "workspace_id" => "w1",
      "tab_id" => "w1:t2",
      "terminal_id" => terminal
    }

    agent =
      Map.merge(pane, %{
        "agent" => "pi",
        "name" => "run-agent",
        "agent_status" => status,
        "interactive_ready" => true,
        "launch_pending" => false
      })

    base
    |> update_in([:snapshot, "tabs"], &(&1 ++ [%{"workspace_id" => "w1", "tab_id" => "w1:t2"}]))
    |> update_in(
      [:snapshot, "panes"],
      &(&1 ++
          [
            pane,
            %{
              "pane_id" => "w1:p10",
              "workspace_id" => "w1",
              "tab_id" => "w1:t2",
              "terminal_id" => "other"
            }
          ])
    )
    |> update_in([:snapshot, "agents"], &(&1 ++ [agent]))
  end

  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met")

      true ->
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
    end
  end

  defp config(key, value) do
    old = Application.fetch_env(:jarvis2, key)
    Application.put_env(:jarvis2, key, value)

    on_exit(fn ->
      case old do
        {:ok, previous} -> Application.put_env(:jarvis2, key, previous)
        :error -> Application.delete_env(:jarvis2, key)
      end
    end)
  end
end
