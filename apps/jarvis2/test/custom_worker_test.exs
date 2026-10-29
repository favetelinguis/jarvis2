defmodule Jarvis2.CustomWorkerTest do
  use ExUnit.Case, async: false

  setup do
    dir =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "worker-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "herdr.sock")

    pane = %{
      "pane_id" => "w1:p1",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "terminal_id" => "term1",
      "cwd" => File.cwd!()
    }

    {:ok, fixture} =
      Agent.start_link(fn ->
        %{
          snapshot: %{"panes" => [pane], "agents" => []},
          process: :ours,
          drop_start: false,
          block_delay: 0
        }
      end)

    parent = self()

    handler = fn req ->
      method = req["method"]
      send(parent, {:herdr, method, req["params"]})

      case method do
        "session.snapshot" ->
          {:reply,
           %{result: %{type: "session_snapshot", snapshot: Agent.get(fixture, & &1.snapshot)}}}

        "pane.process_info" ->
          processes =
            if Agent.get(fixture, & &1.process) == :ours,
              do: [%{pid: String.to_integer(System.pid()), name: "beam.smp"}],
              else: [%{pid: 123, name: "other"}]

          {:reply,
           %{
             result: %{
               type: "pane_process_info",
               process_info: %{
                 pane_id: "w1:p1",
                 foreground_process_group_id: 42,
                 foreground_processes: processes
               }
             }
           }}

        "pane.report_agent" ->
          Agent.update(fixture, fn state ->
            agent =
              Map.merge(pane, %{
                "agent" => req["params"]["agent"],
                "agent_status" => req["params"]["state"]
              })

            put_in(state.snapshot["agents"], [agent])
          end)

          cond do
            Agent.get(fixture, & &1.drop_start) and req["params"]["state"] == "working" ->
              :close

            req["params"]["state"] == "blocked" and Agent.get(fixture, & &1.block_delay) > 0 ->
              {:later, Agent.get(fixture, & &1.block_delay), %{result: %{type: "ok"}}}

            true ->
              {:reply, %{result: %{type: "ok"}}}
          end

        _ ->
          {:reply, %{error: %{code: "unexpected", message: "unexpected"}}}
      end
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    socket = start_supervised!({Jarvis2.Herdr.Socket, [name: nil, path: path]})
    replace_config(:herdr_socket, socket)
    replace_config(:live, true)
    replace_config(:live_scenarios, [:custom_worker])
    replace_config(:mix_project_dir, File.cwd!())
    replace_config(:mix_executable, "/bin/echo")
    previous = System.get_env("HERDR_PANE_ID")
    System.put_env("HERDR_PANE_ID", "w1:p1")

    on_exit(fn ->
      if previous,
        do: System.put_env("HERDR_PANE_ID", previous),
        else: System.delete_env("HERDR_PANE_ID")

      :gen_tcp.close(listener)
      File.rm_rf!(dir)
    end)

    %{fixture: fixture, dir: dir}
  end

  test "a Mix job reports working then completion on the server's own foreground pane" do
    assert {:ok, %{exit_status: 0}} = Jarvis2.MCP.MixRunner.run("compile", nil)

    assert_receive {:herdr, "pane.report_agent",
                    %{
                      "pane_id" => "w1:p1",
                      "source" => "custom:jarvis2",
                      "agent" => "jarvis2-mix",
                      "state" => "working"
                    }},
                   1_000

    assert_receive {:herdr, "pane.report_agent", %{"state" => "idle"}}, 1_000
  end

  test "a failed job reports blocked" do
    replace_config(:mix_executable, "/bin/false")
    assert {:ok, %{exit_status: status}} = Jarvis2.MCP.MixRunner.run("compile", nil)
    assert status != 0
    assert_receive {:herdr, "pane.report_agent", %{"state" => "working"}}, 1_000
    assert_receive {:herdr, "pane.report_agent", %{"state" => "blocked"}}, 1_000
  end

  test "never reports on a pane whose foreground process is not this VM", ctx do
    Agent.update(ctx.fixture, &%{&1 | process: :other})
    assert {:ok, %{exit_status: 0}} = Jarvis2.MCP.MixRunner.run("compile", nil)
    refute_receive {:herdr, "pane.report_agent", _}, 150
  end

  test "never overwrites a detected agent", ctx do
    Agent.update(ctx.fixture, fn state ->
      agent =
        Map.merge(hd(state.snapshot["panes"]), %{"agent" => "pi", "agent_status" => "working"})

      put_in(state.snapshot["agents"], [agent])
    end)

    assert {:ok, %{exit_status: 0}} = Jarvis2.MCP.MixRunner.run("compile", nil)
    refute_receive {:herdr, "pane.report_agent", _}, 150
  end

  test "reports blocked if the Mix caller dies before completion", ctx do
    mix = slow_mix(ctx.dir)
    replace_config(:mix_executable, mix)
    {:ok, caller} = Task.start(fn -> Jarvis2.MCP.MixRunner.run("compile", nil) end)
    assert_receive {:herdr, "pane.report_agent", %{"state" => "working"}}, 1_000
    Process.exit(caller, :kill)
    assert_receive {:herdr, "pane.report_agent", %{"state" => "blocked"}}, 2_000
  end

  test "does not update the pane after another agent takes it over", ctx do
    mix = slow_mix(ctx.dir)
    replace_config(:mix_executable, mix)
    task = Task.async(fn -> Jarvis2.MCP.MixRunner.run("compile", nil) end)
    assert_receive {:herdr, "pane.report_agent", %{"state" => "working"}}, 1_000

    Agent.update(ctx.fixture, fn state ->
      agent =
        Map.merge(hd(state.snapshot["panes"]), %{"agent" => "pi", "agent_status" => "working"})

      put_in(state.snapshot["agents"], [agent])
    end)

    assert {:ok, %{exit_status: 0}} = Task.await(task, 4_000)
    refute_receive {:herdr, "pane.report_agent", %{"state" => "idle"}}, 150
  end

  test "serializes worker reports across a dead caller and a new job", ctx do
    Agent.update(ctx.fixture, &%{&1 | block_delay: 400})
    replace_config(:mix_executable, slow_mix(ctx.dir))
    {:ok, caller} = Task.start(fn -> Jarvis2.MCP.MixRunner.run("compile", nil) end)
    assert_receive {:herdr, "pane.report_agent", %{"state" => "working"}}, 1_000
    Process.exit(caller, :kill)
    assert_receive {:herdr, "pane.report_agent", %{"state" => "blocked"}}, 1_000
    assert {:ok, %{exit_status: 0}} = Jarvis2.MCP.MixRunner.run("compile", nil)
    refute_receive {:herdr, "pane.report_agent", %{"state" => "working"}}, 150
  end

  test "does not retry an uncertain start or assume it can finish it", ctx do
    Agent.update(ctx.fixture, &%{&1 | drop_start: true})
    assert {:ok, %{exit_status: 0}} = Jarvis2.MCP.MixRunner.run("compile", nil)
    assert_receive {:herdr, "pane.report_agent", %{"state" => "working"}}, 1_000
    refute_receive {:herdr, "pane.report_agent", _}, 200
  end

  test "does not perform worker writes without the scenario gate" do
    replace_config(:live_scenarios, [])
    assert {:ok, %{exit_status: 0}} = Jarvis2.MCP.MixRunner.run("compile", nil)
    refute_receive {:herdr, "pane.report_agent", _}, 150
  end

  defp slow_mix(dir) do
    path = Path.join(dir, "slow-mix")
    File.write!(path, "#!/bin/sh\nsleep 1\n")
    File.chmod!(path, 0o700)
    path
  end

  defp replace_config(key, value) do
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
