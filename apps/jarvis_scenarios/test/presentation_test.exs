defmodule Jarvis2.PresentationTest do
  use ExUnit.Case, async: false

  alias Jarvis2.Herdr.Socket
  alias Jarvis2.Scenarios.Presentation

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
    def handle_call({:put, view}, _from, _state), do: {:reply, :ok, view}
  end

  setup do
    state_dir = Application.fetch_env!(:jarvis2, :state_dir)
    path = Path.join(state_dir, "presentation-#{System.unique_integer([:positive])}")
    parent = self()

    handler = fn request ->
      send(parent, {:write, request})
      {:reply, %{result: %{type: "ok"}}}
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Socket, [name: nil, path: path]})
    previous_live = Application.fetch_env(:jarvis2, :live)
    previous_scenarios = Application.fetch_env(:jarvis2, :live_scenarios)
    Application.put_env(:jarvis2, :live, true)
    Application.put_env(:jarvis2, :live_scenarios, [:sidebar_tokens, :pane_hygiene])

    on_exit(fn ->
      restore(:live, previous_live)
      restore(:live_scenarios, previous_scenarios)
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    %{socket: socket}
  end

  test "defers status, tool, and hygiene updates until the mirror is fresh", %{socket: socket} do
    initial = view(true)
    {:ok, mirror} = start_supervised({Mirror, initial})

    start_supervised!(
      {Presentation, [name: nil, mirror: mirror, socket: socket, debounce_ms: 20]}
    )

    caller = %{
      pane: "w1:p1",
      workspace: "w1",
      tab: "w1:t1",
      agent_kind: "pi",
      agent_name: "worker"
    }

    Jarvis2.Bus.publish("herdr:pane.agent_status_changed", %{
      data: %{"pane_id" => "w1:p1", "workspace_id" => "w1", "agent_status" => "working"}
    })

    Jarvis2.Bus.publish("mcp:tool_call", %{caller: caller, tool: "log", outcome: "ok"})
    Jarvis2.Bus.publish("mcp:tool_call", %{caller: caller, tool: "report_status", outcome: "ok"})
    Jarvis2.Bus.publish("mcp:status_reported", %{caller: caller, summary: "ship feature"})

    Jarvis2.Bus.publish("herdr:pane.agent_detected", %{
      data: %{"pane_id" => "w1:p1", "workspace_id" => "w1", "agent" => "pi", "released" => false}
    })

    refute_receive {:write, _}, 100
    fresh = view(false)
    :ok = GenServer.call(mirror, {:put, fresh})
    Jarvis2.Bus.publish("mirror:updated", %{source: mirror, view: fresh})

    assert_receive {:write,
                    %{
                      "method" => "pane.report_metadata",
                      "params" => %{
                        "pane_id" => "w1:p1",
                        "tokens" => %{"agent_state" => "working"},
                        "ttl_ms" => 60_000
                      }
                    }},
                   1_000

    assert_receive {:write,
                    %{
                      "method" => "workspace.report_metadata",
                      "params" => %{
                        "workspace_id" => "w1",
                        "tokens" => %{"last_tool" => "report_status"},
                        "ttl_ms" => 60_000
                      }
                    }},
                   1_000

    assert_receive {:write,
                    %{
                      "method" => "pane.rename",
                      "params" => %{"pane_id" => "w1:p1", "label" => "pi: ship feature"}
                    }},
                   1_000

    assert_receive {:write,
                    %{
                      "method" => "tab.rename",
                      "params" => %{"tab_id" => "w1:t1", "label" => "feature/task"}
                    }},
                   1_000

    refute_receive {:write, _}, 100
  end

  test "ignores stale or mismatched events and does not guess a branch", %{socket: socket} do
    fresh = view(false) |> put_in([:worktrees], %{})
    {:ok, mirror} = start_supervised({Mirror, fresh})

    start_supervised!(
      {Presentation, [name: nil, mirror: mirror, socket: socket, debounce_ms: 20]}
    )

    caller = %{
      pane: "w1:p1",
      workspace: "w2",
      tab: "w1:t1",
      agent_kind: "pi",
      agent_name: "worker"
    }

    Jarvis2.Bus.publish("mcp:tool_call", %{caller: caller, tool: "log", outcome: "ok"})

    Jarvis2.Bus.publish("herdr:pane.agent_status_changed", %{
      data: %{"pane_id" => "w1:p1", "workspace_id" => "w1", "agent_status" => "done"}
    })

    Jarvis2.Bus.publish("mcp:status_reported", %{caller: caller, summary: "wrong workspace"})
    refute_receive {:write, _}, 150

    Jarvis2.Bus.publish("herdr:pane.agent_detected", %{
      data: %{"pane_id" => "w1:p1", "workspace_id" => "w1", "agent" => "pi", "released" => false}
    })

    assert_receive {:write,
                    %{
                      "method" => "pane.rename",
                      "params" => %{"pane_id" => "w1:p1", "label" => "pi"}
                    }},
                   1_000

    refute_receive {:write, _}, 100
  end

  test "pane hygiene remains dry when only sidebar tokens are enabled", %{socket: socket} do
    Application.put_env(:jarvis2, :live_scenarios, [:sidebar_tokens])
    fresh = view(false)
    {:ok, mirror} = start_supervised({Mirror, fresh})

    start_supervised!(
      {Presentation, [name: nil, mirror: mirror, socket: socket, debounce_ms: 20]}
    )

    Jarvis2.Bus.publish("herdr:pane.agent_detected", %{
      data: %{"pane_id" => "w1:p1", "workspace_id" => "w1", "agent" => "pi"}
    })

    Jarvis2.Bus.publish("mcp:tool_call", %{caller: %{pane: "w1:p1", workspace: "w1"}, tool: "log"})

    assert_receive {:write, %{"method" => "workspace.report_metadata"}}, 1_000
    refute_receive {:write, _}, 150
  end

  test "drops deferred updates if the pane moved before reconciliation", %{socket: socket} do
    {:ok, mirror} = start_supervised({Mirror, view(true)})

    start_supervised!(
      {Presentation, [name: nil, mirror: mirror, socket: socket, debounce_ms: 20]}
    )

    caller = %{
      pane: "w1:p1",
      workspace: "w1",
      tab: "w1:t1",
      agent_kind: "pi",
      agent_name: "worker"
    }

    Jarvis2.Bus.publish("mcp:tool_call", %{caller: caller, tool: "log"})
    Jarvis2.Bus.publish("mcp:status_reported", %{caller: caller, summary: "task"})
    refute_receive {:write, _}, 100
    moved = put_in(view(false), [:snapshot, "panes", Access.at(0), "workspace_id"], "w2")
    :ok = GenServer.call(mirror, {:put, moved})
    Jarvis2.Bus.publish("mirror:updated", %{source: mirror, view: moved})
    refute_receive {:write, _}, 150
  end

  test "a timed-out rename is not retried after mirror updates" do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "presentation-timeout-#{System.unique_integer([:positive])}"
      )

    parent = self()

    handler = fn request ->
      send(parent, {:attempt, request})
      {:later, 1_500, %{result: %{type: "ok"}}}
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Socket, [name: nil, path: path]}, id: :timeout_socket)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    fresh = put_in(view(false), [:worktrees], %{})
    {:ok, mirror} = start_supervised({Mirror, fresh})

    start_supervised!(
      {Presentation, [name: nil, mirror: mirror, socket: socket, debounce_ms: 20]}
    )

    Jarvis2.Bus.publish("herdr:pane.agent_detected", %{
      data: %{"pane_id" => "w1:p1", "workspace_id" => "w1", "agent" => "pi"}
    })

    assert_receive {:attempt, %{"method" => "pane.rename"}}, 1_000
    Process.sleep(1_100)
    Jarvis2.Bus.publish("mirror:updated", %{source: mirror, view: fresh})
    refute_receive {:attempt, _}, 600
  end

  defp view(stale) do
    %{
      stale: stale,
      snapshot: %{
        "workspaces" => [
          %{
            "workspace_id" => "w1",
            "worktree" => %{"repo_key" => "repo", "checkout_path" => "/repo/work"}
          }
        ],
        "tabs" => [%{"tab_id" => "w1:t1", "workspace_id" => "w1", "label" => "old"}],
        "panes" => [
          %{"pane_id" => "w1:p1", "workspace_id" => "w1", "tab_id" => "w1:t1", "label" => "old"}
        ],
        "agents" => [
          %{
            "pane_id" => "w1:p1",
            "workspace_id" => "w1",
            "agent" => "pi",
            "name" => "worker",
            "agent_status" => "working"
          }
        ]
      },
      worktrees: %{"repo" => [%{"path" => "/repo/work", "branch" => "feature/task"}]},
      worktree_errors: %{}
    }
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:jarvis2, key, value)
  defp restore(key, :error), do: Application.delete_env(:jarvis2, key)
end
