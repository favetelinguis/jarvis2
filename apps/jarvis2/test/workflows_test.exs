defmodule Jarvis2.WorkflowsTest do
  use Jarvis2.DataCase, async: false
  alias Jarvis2.Automations.TestLoop

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

    def handle_call({:req, "tab.create", params}, from, s) do
      {:reply, {:reply, %{result: %{pane: pane}}}, s} =
        handle_call({:req, "pane.split", params}, from, s)

      {:reply, {:reply, %{result: %{type: "tab_created", root_pane: pane}}}, s}
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

    def handle_call({:req, "pane.wait_for_output", %{"pane_id" => pane}}, _, s),
      do: {:reply, {:reply, %{result: %{type: "output_matched", pane_id: pane}}}, s}

    def handle_call({:req, "pane.read", %{"pane_id" => pane}}, _, s) do
      read = %{pane_id: pane, workspace_id: "w1", tab_id: "w1:t1", text: s.output}
      {:reply, {:reply, %{result: %{type: "pane_read", read: read}}}, s}
    end

    def handle_call({:req, ok, _}, _, s)
        when ok in ["pane.send_input", "agent.prompt"],
        do: {:reply, {:reply, %{result: %{type: "ok"}}}, s}

    def handle_call({:req, _, _}, _, s),
      do: {:reply, {:reply, %{error: %{code: "unexpected_method", message: "unexpected"}}}, s}
  end

  defp boot(opts) do
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
    config(:live_scenarios, [])
    world
  end

  defp status_change(status),
    do:
      Phoenix.PubSub.local_broadcast(
        Jarvis2.PubSub,
        "herdr:pane.agent_status_changed",
        {:jarvis2, "herdr:pane.agent_status_changed",
         %{
           data: %{"pane_id" => "w1:p1", "agent_status" => status}
         }}
      )

  test "test loop runs mix test after a turn and prompts the agent only on failure" do
    boot(agent: "idle", output: "1 failure\nJARVIS2_EXIT_2\n")
    start_supervised!({TestLoop, [name: nil]})
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "scenario:test_loop")
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

    assert [%{type: "automation.test_loop", outcome: :error, payload: %{"result" => "failed"}}] =
             Jarvis2.Journal.recent(source: :automation)
  end

  test "test loop does not prompt when tests pass, in dry mode, or outside the project" do
    boot(agent: "idle", output: "ok\nJARVIS2_EXIT_0\n")
    start_supervised!({TestLoop, [name: nil]})
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "scenario:test_loop")
    status_change("working")
    status_change("idle")
    refute_receive {:request, _, _}, 200

    config(:live_scenarios, [:test_loop, :run_command, :agent_prompt])
    status_change("working")
    status_change("idle")
    assert_receive {:jarvis2, "scenario:test_loop", %{result: :passed}}, 5_000
    refute_receive {:request, "agent.prompt", _}, 100

    assert [%{type: "automation.test_loop", outcome: :ok}] =
             Jarvis2.Journal.recent(source: :automation)

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
