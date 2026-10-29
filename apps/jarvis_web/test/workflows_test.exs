defmodule Jarvis2.WorkflowsTest do
  use ExUnit.Case, async: false
  alias Jarvis2.Scenarios.{ReviewDiff, TestLoop, WorktreeTask}

  # One process plays both Herdr and the mirror so they never disagree.
  defmodule World do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts) do
      pane = %{
        "pane_id" => "w1:p1",
        "workspace_id" => "w1",
        "tab_id" => "w1:t1",
        "terminal_id" => "term1",
        "cwd" => File.cwd!()
      }

      workspace = %{"workspace_id" => "w1", "active_tab_id" => "w1:t1"}

      workspace =
        if opts[:worktree] == false,
          do: workspace,
          else: Map.put(workspace, "worktree", tree(false))

      agents =
        if opts[:agent],
          do: [agent("w1:p1", "term1", "w1", "w1:t1", "work", opts[:agent])],
          else: []

      {:ok,
       %{
         counter: 1,
         output: opts[:output] || "",
         wait_working: opts[:wait_working] != false,
         snapshot: %{
           "workspaces" => [workspace],
           "tabs" => [%{"tab_id" => "w1:t1", "workspace_id" => "w1"}],
           "panes" => [pane],
           "agents" => agents,
           "layouts" => []
         }
       }}
    end

    defp tree(linked),
      do: %{"repo_key" => "/r/.git", "repo_name" => "r", "is_linked_worktree" => linked}

    defp agent(pane, terminal, workspace, tab, name, status),
      do: %{
        "pane_id" => pane,
        "terminal_id" => terminal,
        "workspace_id" => workspace,
        "tab_id" => tab,
        "agent" => "pi",
        "name" => name,
        "agent_status" => status,
        "interactive_ready" => true
      }

    def handle_call(:get, _, s),
      do: {:reply, %{snapshot: s.snapshot, stale: false, worktrees: %{}, worktree_errors: %{}}, s}

    def handle_call({:req, "session.snapshot", _}, _, s),
      do: {:reply, {:reply, %{result: %{type: "session_snapshot", snapshot: s.snapshot}}}, s}

    def handle_call({:req, "worktree.list", %{"workspace_id" => id}}, _, s) do
      workspace = Enum.find(s.snapshot["workspaces"], &(&1["workspace_id"] == id))

      reply =
        case workspace do
          %{"worktree" => %{"repo_key" => repo_key}} ->
            %{result: %{type: "worktree_list", source: %{repo_key: repo_key}, worktrees: []}}

          _ ->
            %{error: %{code: "not_a_git_repository", message: "not a repository"}}
        end

      {:reply, {:reply, reply}, s}
    end

    def handle_call({:req, "worktree.create", params}, _, s) do
      ws = %{
        "workspace_id" => "w2",
        "active_tab_id" => "w2:t1",
        "worktree" => tree(true),
        "label" => params["label"]
      }

      pane = %{
        "pane_id" => "w2:p1",
        "workspace_id" => "w2",
        "tab_id" => "w2:t1",
        "terminal_id" => "term-w2",
        "cwd" => "/tmp"
      }

      s = update_in(s.snapshot["workspaces"], &(&1 ++ [ws]))
      s = update_in(s.snapshot["panes"], &(&1 ++ [pane]))
      reply = %{result: %{type: "worktree_created", workspace: ws, root_pane: pane}}
      {:reply, {:reply, reply}, s}
    end

    def handle_call({:req, "pane.split", params}, _, s) do
      n = s.counter + 1

      pane = %{
        "pane_id" => "w1:p#{n}",
        "workspace_id" => "w1",
        "tab_id" => "w1:t1",
        "terminal_id" => "term#{n}",
        "cwd" => params["cwd"]
      }

      s = %{s | counter: n}
      s = update_in(s.snapshot["panes"], &(&1 ++ [pane]))
      {:reply, {:reply, %{result: %{type: "pane_info", pane: pane}}}, s}
    end

    def handle_call({:req, "pane.process_info", %{"pane_id" => pane}}, _, s) do
      info = %{
        pane_id: pane,
        shell_pid: 42,
        foreground_process_group_id: 42,
        foreground_processes: [%{pid: 42, name: "sh"}]
      }

      {:reply, {:reply, %{result: %{type: "pane_process_info", process_info: info}}}, s}
    end

    def handle_call({:req, "agent.start", params}, _, s) do
      pane = Enum.find(s.snapshot["panes"], &(&1["pane_id"] == params["pane_id"]))

      agent =
        agent(
          pane["pane_id"],
          pane["terminal_id"],
          pane["workspace_id"],
          pane["tab_id"],
          params["name"],
          "working"
        )

      s = update_in(s.snapshot["agents"], &(&1 ++ [agent]))

      pending =
        agent
        |> Map.delete("agent")
        |> Map.put("launch_pending", true)
        |> Map.put("agent_status", "unknown")

      {:reply, {:reply, %{result: %{type: "agent_started", agent: pending}}}, s}
    end

    def handle_call({:req, "pane.wait_for_output", %{"pane_id" => pane}}, _, s),
      do: {:reply, {:reply, %{result: %{type: "output_matched", pane_id: pane}}}, s}

    def handle_call({:req, "pane.read", %{"pane_id" => pane}}, _, s) do
      read = %{pane_id: pane, workspace_id: "w1", tab_id: "w1:t1", text: s.output}
      {:reply, {:reply, %{result: %{type: "pane_read", read: read}}}, s}
    end

    def handle_call(
          {:req, "agent.wait", %{"until" => ["working"]}},
          _,
          %{wait_working: false} = s
        ),
        do: {:reply, {:reply, %{error: %{code: "timeout", message: "timeout"}}}, s}

    def handle_call({:req, "agent.wait", _}, _, s),
      do: {:reply, {:reply, %{result: %{type: "agent_wait"}}}, s}

    def handle_call({:req, "agent.read", _}, _, s),
      do:
        {:reply, {:reply, %{result: %{type: "agent_read", read: %{text: "finding: private"}}}}, s}

    def handle_call({:req, ok, _}, _, s)
        when ok in ["pane.send_input", "agent.prompt", "plugin.pane.open"],
        do: {:reply, {:reply, %{result: %{type: "ok"}}}, s}

    def handle_call({:req, _, _}, _, s),
      do: {:reply, {:reply, %{error: %{code: "unexpected_method", message: "unexpected"}}}, s}
  end

  defp boot(opts \\ []) do
    parent = self()
    world = start_supervised!({World, opts})

    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "workflow-#{System.unique_integer([:positive])}"
      )

    handler = fn %{"method" => method, "params" => params} ->
      send(parent, {:request, method, params})
      GenServer.call(world, {:req, method, params})
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    socket = start_supervised!({Jarvis2.Herdr.Socket, [name: nil, path: path]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    config(:mirror, world)
    config(:herdr_socket, socket)
    config(:execution_guard, start_supervised!({Jarvis2.Herdr.ExecutionGuard, [name: nil]}))
    config(:prompt_guard, start_supervised!({Jarvis2.Herdr.PromptGuard, [name: nil]}))
    config(:live, false)
    config(:live_scenarios, [])
    world
  end

  defp action(id, extra \\ %{}) do
    body =
      Map.merge(%{"context" => %{"workspace_id" => "w1", "focused_pane_id" => "w1:p1"}}, extra)

    Jarvis2.Web.Hooks.accept("action", id, body)
  end

  defp status_change(status),
    do:
      Jarvis2.Bus.publish("herdr:pane.agent_status_changed", %{
        data: %{"pane_id" => "w1:p1", "agent_status" => status}
      })

  defp flush_requests do
    receive do
      {:request, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  test "parses issue URLs and task names conservatively" do
    assert {:ok, %{slug: "issue-12", prompt: "Work on https://github.com/a/b/issues/12"}} =
             WorktreeTask.parse_issue("https://github.com/a/b/issues/12")

    assert {:ok, %{slug: "pr-3"}} = WorktreeTask.parse_issue("https://github.com/a/b/pull/3")
    assert :error = WorktreeTask.parse_issue("https://github.com/a/b/issues/12?x=1")
    assert :error = WorktreeTask.parse_issue("https://evil.example/a/b/issues/1")
    assert :error = WorktreeTask.parse_issue("https://github.com.evil.example/a/b/issues/1")
    assert {:ok, "fix-the-bug"} = WorktreeTask.slugify("  Fix the BUG!! ")
    assert :error = WorktreeTask.slugify("../..")
  end

  test "issue-link is a dry run unless both scenarios are live" do
    boot()
    start_supervised!({WorktreeTask, [name: nil]})
    config(:live, true)
    config(:live_scenarios, [:worktree_task])
    action("issue-link", %{"clicked_url" => "https://github.com/a/b/issues/7"})
    refute_receive {:request, _, _}, 200
  end

  test "issue-link creates a linked worktree and starts an agent with the issue as its launch argument" do
    boot()
    start_supervised!({WorktreeTask, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:worktree_task")
    config(:live, true)
    config(:live_scenarios, [:worktree_task, :agent_spawn])
    action("issue-link", %{"clicked_url" => "https://github.com/a/b/issues/7"})

    assert_receive {:request, "worktree.create",
                    %{"workspace_id" => "w1", "branch" => "task/issue-7", "focus" => false}},
                   2_000

    assert_receive {:request, "agent.start",
                    %{
                      "pane_id" => "w2:p1",
                      "args" => ["Work on https://github.com/a/b/issues/7"]
                    }},
                   5_000

    assert_receive {:jarvis2, "scenario:worktree_task", %{workspace: "w1", outcome: :ok}}, 5_000
    refute_receive {:request, "agent.prompt", _}, 100
  end

  test "issue-link refuses bad URLs and workspaces that are not Git worktrees" do
    boot(worktree: false)
    start_supervised!({WorktreeTask, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:worktree_task")
    config(:live, true)
    config(:live_scenarios, [:worktree_task, :agent_spawn])
    action("issue-link", %{"clicked_url" => "https://github.com/a/b/issues/7?x=1"})
    refute_receive {:request, _, _}, 150
    action("issue-link", %{"clicked_url" => "https://github.com/a/b/issues/7"})
    assert_receive {:jarvis2, "scenario:worktree_task", %{outcome: :error}}, 5_000
    refute_receive {:request, "worktree.create", _}, 100

    # A failed attempt cools down instead of being retried immediately.
    flush_requests()
    action("issue-link", %{"clicked_url" => "https://github.com/a/b/issues/7"})
    refute_receive {:request, _, _}, 200
  end

  test "new-task asks a human for a name and prompt, then creates the worktree agent" do
    boot()
    start_supervised!({Finch, name: Jarvis2.WorkflowsFinch})
    server = start_supervised!({Bandit, plug: Jarvis2.Web.Router, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    config(:port, port)
    start_supervised!({WorktreeTask, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:worktree_task")
    config(:live, true)
    config(:live_scenarios, [:human_picker, :worktree_task, :agent_spawn])
    action("new-task")

    answer = fn text ->
      assert_receive {:request, "plugin.pane.open", %{"env" => %{"JARVIS2_PICKER_ID" => id}}},
                     2_000

      headers = [
        {"authorization", "Bearer " <> Jarvis2.Token.get()},
        {"content-type", "application/json"}
      ]

      request =
        Finch.build(
          :post,
          "http://127.0.0.1:#{port}/picker/#{id}",
          headers,
          Jason.encode!(%{text: text})
        )

      assert {:ok, %{status: 200}} = Finch.request(request, Jarvis2.WorkflowsFinch)
    end

    answer.("Fix the Bug!")
    answer.("make it pass")

    assert_receive {:request, "worktree.create", %{"branch" => "task/fix-the-bug"}}, 5_000
    assert_receive {:request, "agent.start", %{"args" => ["Task: make it pass"]}}, 5_000
    assert_receive {:jarvis2, "scenario:worktree_task", %{outcome: :ok}}, 5_000
  end

  test "new-task does not open a picker unless every gate is live" do
    boot()
    start_supervised!({WorktreeTask, [name: nil]})
    config(:live, true)
    config(:live_scenarios, [:worktree_task, :agent_spawn])
    action("new-task")
    refute_receive {:request, _, _}, 200
  end

  test "review fan-out starts bounded reviewers and merges their output" do
    boot()
    start_supervised!({ReviewDiff, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:review_diff")
    config(:live, true)
    config(:live_scenarios, [:review_fanout, :agent_spawn])
    config(:review_focuses, ["bugs", "tests"])
    action("review-diff")

    for pane <- ["w1:p2", "w1:p3"] do
      assert_receive {:request, "agent.start", %{"pane_id" => ^pane, "args" => [instruction]}},
                     8_000

      assert instruction =~ "Do not modify files"
    end

    assert_receive {:jarvis2, "scenario:review_diff", %{reviews: 2}}, 10_000

    assert {:ok,
            %{reviews: [%{focus: "bugs", status: "finished", output: "finding: private"}, _]}} =
             Jarvis2.State.get("review:latest")
  end

  test "review fan-out flags results when the agent never reported working" do
    boot(wait_working: false)

    source = %{
      pane: "w1:p1",
      workspace: "w1",
      tab: "w1:t1",
      cwd: File.cwd!()
    }

    config(:live, true)
    config(:live_scenarios, [:review_fanout, :agent_spawn])

    assert {:ok, %{reviews: [%{status: "idle_unobserved"}]}} =
             Jarvis2.Herdr.Actions.review_fanout(source, %{focuses: ["bugs"], kind: "pi"})
  end

  test "review fan-out does nothing in dry mode and rejects invalid focuses" do
    boot()
    start_supervised!({ReviewDiff, [name: nil]})
    action("review-diff")
    refute_receive {:request, _, _}, 200

    assert {:error, _} =
             Jarvis2.Herdr.Actions.review_fanout(
               %{pane: "w1:p1", workspace: "w1", tab: "w1:t1", cwd: File.cwd!()},
               %{focuses: ["bad focus"], kind: "pi"}
             )
  end

  test "test loop runs mix test after a turn and prompts the agent only on failure" do
    boot(agent: "idle", output: "1 failure\nJARVIS2_EXIT_2\n")
    start_supervised!({TestLoop, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:test_loop")
    config(:live, true)
    config(:live_scenarios, [:test_loop, :run_command, :agent_prompt])
    status_change("working")
    status_change("idle")

    assert_receive {:request, "pane.send_input", %{"text" => command}}, 5_000
    assert command =~ "mix test"
    assert_receive {:request, "pane.wait_for_output", %{"match" => %{"type" => "regex"}}}, 2_000

    assert_receive {:request, "agent.prompt", %{"target" => "w1:p1", "text" => text}}, 5_000
    assert text =~ "failed (exit 2)"
    refute text =~ "JARVIS2_EXIT"
    assert_receive {:jarvis2, "scenario:test_loop", %{result: :failed}}, 5_000
  end

  test "test loop does not prompt when tests pass, in dry mode, or outside the project" do
    boot(agent: "idle", output: "ok\nJARVIS2_EXIT_0\n")
    start_supervised!({TestLoop, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:test_loop")
    status_change("working")
    status_change("idle")
    refute_receive {:request, _, _}, 200

    config(:live, true)
    config(:live_scenarios, [:test_loop, :run_command, :agent_prompt])
    status_change("working")
    status_change("idle")
    assert_receive {:jarvis2, "scenario:test_loop", %{result: :passed}}, 5_000
    refute_receive {:request, "agent.prompt", _}, 100

    refute TestLoop.trusted_project?("/tmp")
    refute TestLoop.trusted_project?(nil)
  end

  test "test loop output is stripped of terminal control sequences" do
    assert TestLoop.clean_tail("a\e[31mred\e[0m\x07 JARVIS2_EXIT_1") == "ared "
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
