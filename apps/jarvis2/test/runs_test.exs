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

    test "validates user input", %{cwd: cwd} do
      attrs = %{name: "demo", task: "x", cwd: cwd}

      for bad <- [
            %{name: ""},
            %{task: String.duplicate("x", 6_001)},
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
               ~w(--provider openrouter --model openai/gpt-6-luna --thinking low --extension /home/favetelinguis/repos/jarvis2/.pi/jarvis2-run.js)

      assert_receive {:request, "agent.prompt", %{"target" => "w1:p9", "text" => text}}
      assert text =~ ~s(run "demo")
      assert text =~ "ask_human"
      assert text =~ "request_approval"
      assert text =~ "submit_result"
      assert String.ends_with?(text, "Task:\nwrite the report")
      assert byte_size(text) <= 8_192

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

    test "creates the workspace when no anchor exists", ctx do
      live!()
      empty = update_in(view(), [:snapshot], &Map.merge(&1, %{"workspaces" => [], "panes" => []}))
      :ok = GenServer.call(ctx.mirror, {:put, empty})
      {:ok, run} = Runs.create_run(%{name: "demo", task: "t", cwd: ctx.cwd})

      assert %Run{status: :working} = Runs.launch(run)

      assert_receive {:request, "workspace.create",
                      %{"label" => "jarvis2", "cwd" => cwd, "focus" => false}}

      assert cwd == ctx.cwd
      assert_receive {:request, "tab.create", %{"workspace_id" => "w1"}}
    end

    test "a rejected workspace creation does not create a tab", ctx do
      live!()
      empty = update_in(view(), [:snapshot], &Map.merge(&1, %{"workspaces" => [], "panes" => []}))
      :ok = GenServer.call(ctx.mirror, {:put, empty})
      Agent.update(ctx.behavior, &Map.put(&1, "workspace.create", {:error, "invalid_request"}))
      {:ok, run} = Runs.create_run(%{name: "demo", task: "t", cwd: ctx.cwd})
      assert %Run{status: :failed, result: %{"error" => message}} = Runs.launch(run)
      assert message =~ "inspect the session before retrying"
      assert_receive {:request, "workspace.create", _}
      refute_receive {:request, "tab.create", _}, 100
    end

    test "anchor ignores focused panes in other workspaces" do
      other = %{"workspace_id" => "w2", "label" => "other"}
      other_pane = %{"workspace_id" => "w2", "pane_id" => "w2:p1"}

      snapshot =
        view().snapshot
        |> Map.put("focused_pane_id", "w2:p1")
        |> Map.update!("workspaces", &[other | &1])
        |> Map.update!("panes", &[other_pane | &1])

      assert {:ok, %{"pane_id" => "w1:p1"}} = Launcher.anchor(%{snapshot: snapshot})

      assert {:error, :no_anchor} =
               Launcher.anchor(%{snapshot: %{snapshot | "workspaces" => [other]}})
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

      assert {:error, "The prompt is too long."} =
               Runs.prompt_run(run, String.duplicate("x", 6_001))
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
      assert length(Runs.list_runs()) == 1
      assert_receive {:request, "tab.create", %{"label" => label}}, 3_000
      assert label == String.slice(title, 0, 32)
      assert_receive {:request, "agent.start", _}, 3_000
      assert_receive {:request, "agent.prompt", %{"text" => text}}, 3_000
      assert text =~ "ask_questions"
      assert text =~ "Provide alternatives whenever applicable"
      assert_eventually(fn -> Journal.count(type: "run.start", run_id: moved.run_id) > 0 end)
      assert Runs.get_run(moved.run_id).status == :working
    end

    test "reopen delivers feedback to the same pane", ctx do
      run = working_run(ctx)
      {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Plan this", cwd: ctx.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
      assert {:ok, _} = Jarvis2.Kanban.submit_deliverable(run.id, "The plan")
      card = Jarvis2.Kanban.get_card(card.id)
      assert {:ok, reopened} = Jarvis2.Kanban.reopen(card, "Add alternatives")
      assert reopened.run_id == run.id
      assert_receive {:request, "agent.prompt", %{"text" => text}}, 3_000
      assert text =~ "Add alternatives"
      assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) > 0 end)
      assert length(Runs.list_runs()) == 1
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

      assert [%Run{kind: "mix", name: "mix test", status: :done} = run] = Runs.list_runs()
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
      [mix_run] = Runs.list_runs(status: :failed)
      assert %Run{kind: "mix", parent_run_id: parent_id} = mix_run
      assert parent_id == parent.id
      assert %{outcome: :error} = List.last(Journal.recent(run_id: mix_run.id))
    end

    test "disallowed tasks and projects never create a run", ctx do
      assert {:error, "Mix task is not allowed"} = Runs.run_mix("deps.get", nil)
      assert {:error, "Mix task is not allowed"} = Runs.start_mix("deps.get")
      assert Runs.list_runs() == []

      assert {:error, "project must be the configured trusted project"} =
               Runs.run_mix("test", Path.join(ctx.cwd, "elsewhere"))

      assert [%Run{status: :failed, result: %{"error" => "project" <> _}}] = Runs.list_runs()
    end

    test "Mix runs cannot be stopped and are failed if the server died mid-run", ctx do
      {:ok, _} = Runs.run_mix("test", nil)
      [done] = Runs.list_runs()
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
      {:error, code} -> {:reply, %{error: %{code: code, message: "simulated"}}}
    end
  end

  defp respond(%{"method" => "workspace.create"}, _mirror, _) do
    pane = %{pane_id: "w1:p1", terminal_id: "term-anchor", workspace_id: "w1", tab_id: "w1:t1"}
    {:reply, %{result: %{type: "workspace_created", root_pane: pane}}}
  end

  defp respond(%{"method" => "tab.create"}, _mirror, _) do
    pane = %{pane_id: "w1:p9", terminal_id: "term-run", workspace_id: "w1", tab_id: "w1:t1"}
    {:reply, %{result: %{type: "tab_created", root_pane: pane}}}
  end

  defp respond(%{"method" => "pane.process_info"}, _mirror, _) do
    info = %{
      pane_id: "w1:p9",
      shell_pid: 7,
      foreground_process_group_id: 7,
      foreground_processes: [%{pid: 7}]
    }

    {:reply, %{result: %{type: "pane_process_info", process_info: info}}}
  end

  defp respond(%{"method" => "agent.start", "params" => params}, mirror, _) do
    :ok = GenServer.call(mirror, {:put, with_run_pane("idle")})
    agent = %{pane_id: params["pane_id"], name: params["name"], agent: params["kind"]}
    {:reply, %{result: %{type: "agent_started", agent: agent}}}
  end

  defp respond(%{"method" => "agent.prompt"}, _mirror, _),
    do: {:reply, %{result: %{type: "agent_prompt", submitted: true}}}

  defp respond(%{"method" => "pane.close"}, _mirror, _), do: {:reply, %{result: %{type: "ok"}}}

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
      "tab_id" => "w1:t1",
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
    |> update_in([:snapshot, "panes"], &(&1 ++ [pane]))
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
