defmodule Jarvis2.HerdrEventsTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.Herdr.{Events, Mirror, Socket}

  setup do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "events-#{System.unique_integer([:positive])}"
      )

    parent = self()

    {:ok, fixture} =
      start_supervised(
        {Agent,
         fn -> %{snapshot: snapshot(), delay: 0, pane_delay: 0, disappear: false, busy: 0} end}
      )

    handler = fn request ->
      method = request["method"]
      params = request["params"]
      send(parent, {:fake_request, method, params})

      case method do
        "events.subscribe" ->
          pane_sub = Enum.find(params["subscriptions"], &Map.has_key?(&1, "pane_id"))

          if pane_sub, do: Process.sleep(Agent.get(fixture, & &1.pane_delay))

          if pane_sub && Agent.get(fixture, & &1.disappear) do
            Agent.update(fixture, &%{&1 | snapshot: snapshot(), disappear: false})
            {:reply, %{error: %{code: "pane_not_found", message: "gone"}}}
          else
            {:subscribe, parent}
          end

        "session.snapshot" ->
          state = Agent.get(fixture, & &1)
          {:later, state.delay, %{result: %{type: "session_snapshot", snapshot: state.snapshot}}}

        "worktree.list" ->
          busy =
            Agent.get_and_update(fixture, fn s ->
              {s.busy > 0, %{s | busy: max(s.busy - 1, 0)}}
            end)

          if busy,
            do: {:reply, %{error: %{code: "worktree_busy", message: "busy"}}},
            else: {:reply, %{result: %{worktrees: [%{path: "/repo/other", branch: "other"}]}}}
      end
    end

    {:ok, _fake, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Socket, [path: path, name: nil]})
    {:ok, tasks} = start_supervised({Task.Supervisor, []})

    {:ok, mirror} =
      start_supervised(
        {Mirror, [name: nil, socket: socket, task_supervisor: tasks, retry_ms: 30]}
      )

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    %{fixture: fixture, mirror: mirror, path: path}
  end

  test "subscribes then builds a mirror, retrying worktree discovery", %{
    fixture: fixture,
    mirror: mirror,
    path: path
  } do
    Agent.update(fixture, &%{&1 | snapshot: snapshot(["w1:p1"], true), busy: 1})
    start_events(path, mirror)
    assert_receive {:subscription, _, %{"params" => %{"subscriptions" => lifecycle}}}, 1_000
    assert Enum.any?(lifecycle, &(&1["type"] == "layout.updated"))
    assert_receive {:fake_request, "session.snapshot", _}, 1_000

    eventually(fn ->
      view = Mirror.get(mirror)

      not view.stale and view.snapshot["agents"] != [] and
        view.worktrees["repo-key"] == [%{"path" => "/repo/other", "branch" => "other"}]
    end)

    assert_receive {:subscription, _, %{"params" => %{"subscriptions" => pane_subs}}}, 1_000

    assert Enum.any?(
             pane_subs,
             &(&1["type"] == "pane.output_matched" and &1["pane_id"] == "w1:p1")
           )

    assert Enum.any?(
             pane_subs,
             &(&1["type"] == "pane.agent_status_changed" and &1["pane_id"] == "w1:p1")
           )
  end

  test "events during a snapshot trigger another read", %{
    fixture: fixture,
    mirror: mirror,
    path: path
  } do
    Agent.update(fixture, &%{&1 | delay: 100})
    start_events(path, mirror)
    assert_receive {:subscription, lifecycle, _}, 1_000
    assert_receive {:fake_request, "session.snapshot", _}, 1_000
    Agent.update(fixture, &%{&1 | snapshot: snapshot(["w1:p1"]), delay: 0})

    push(lifecycle, %{
      event: "pane_created",
      data: %{type: "pane_created", pane: %{pane_id: "w1:p1"}}
    })

    eventually(fn ->
      not Mirror.get(mirror).stale and length(Mirror.get(mirror).snapshot["agents"]) == 1
    end)

    assert_receive {:fake_request, "session.snapshot", _}, 1_000
  end

  test "events_lost resubscribes and reconciles against a new snapshot", %{
    fixture: fixture,
    mirror: mirror,
    path: path
  } do
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "mirror:layout_diff")
    start_events(path, mirror)
    assert_receive {:subscription, lifecycle, _}, 1_000
    eventually(fn -> not Mirror.get(mirror).stale end)

    assert_receive {:jarvis2, "mirror:layout_diff",
                    %{source: ^mirror, diff: %{status: "baseline"}}},
                   1_000

    Agent.update(fixture, &%{&1 | snapshot: snapshot(["w1:p2"])})
    push(lifecycle, %{id: "subscribe", error: %{code: "events_lost", message: "lost"}})
    assert_receive {:subscription, replacement, _}, 2_000
    refute lifecycle == replacement

    eventually(fn ->
      not Mirror.get(mirror).stale and
        Enum.any?(Mirror.get(mirror).snapshot["agents"], &(&1["pane_id"] == "w1:p2"))
    end)

    assert_receive {:jarvis2, "mirror:layout_diff",
                    %{source: ^mirror, diff: %{status: "resynced", changes: changes}}},
                   1_000

    assert Enum.any?(changes, &match?(%{kind: "pane", id: "w1:p2", change: "added"}, &1))
  end

  test "a snapshot with an unsubscribed agent is not reported as fresh", %{
    fixture: fixture,
    mirror: mirror
  } do
    Agent.update(fixture, &%{&1 | snapshot: snapshot(["w1:p1"])})
    Mirror.online(mirror)
    eventually(fn -> not is_nil(Mirror.get(mirror).snapshot) end)
    assert Mirror.get(mirror).stale
  end

  test "the mirror remains stale until agent subscriptions are active and reconciled", %{
    fixture: fixture,
    mirror: mirror,
    path: path
  } do
    Agent.update(fixture, &%{&1 | snapshot: snapshot(["w1:p1"]), pane_delay: 200})
    start_events(path, mirror)

    assert_receive {:fake_request, "events.subscribe",
                    %{"subscriptions" => [%{"pane_id" => "w1:p1"} | _]}},
                   1_000

    assert Mirror.get(mirror).stale

    assert_receive {:subscription, _pane,
                    %{"params" => %{"subscriptions" => [%{"pane_id" => "w1:p1"} | _]}}},
                   1_000

    eventually(fn -> not Mirror.get(mirror).stale end)
  end

  test "status reports the mirrored agent counts", %{fixture: fixture, mirror: mirror, path: path} do
    data = snapshot(["w1:p1"])
    data = put_in(data, ["agents", Access.at(0), "agent_status"], "blocked")
    Agent.update(fixture, &%{&1 | snapshot: data})
    start_events(path, mirror)
    assert_receive {:subscription, _lifecycle, _}, 1_000
    assert_receive {:fake_request, "session.snapshot", _}, 1_000
    assert_receive {:subscription, _pane, _}, 1_000
    assert_receive {:fake_request, "session.snapshot", _}, 1_000
    eventually(fn -> not Mirror.get(mirror).stale end)
    previous = Application.get_env(:jarvis2, :mirror)
    Application.put_env(:jarvis2, :mirror, mirror)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:jarvis2, :mirror, previous),
        else: Application.delete_env(:jarvis2, :mirror)
    end)

    conn =
      Plug.Test.conn(:get, "/status") |> Jarvis2Web.Endpoint.call(Jarvis2Web.Endpoint.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "1 agents · 1 blocked"
  end

  test "agent status and output events are published to the bus", %{
    fixture: fixture,
    mirror: mirror,
    path: path
  } do
    Agent.update(fixture, &%{&1 | snapshot: snapshot(["w1:p1"])})
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "herdr:pane.agent_status_changed")
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "herdr:pane.output_matched")
    start_events(path, mirror)
    assert_receive {:subscription, _lifecycle, _}, 1_000
    assert_receive {:subscription, pane, _}, 1_000

    push(pane, %{
      event: "pane.agent_status_changed",
      data: %{pane_id: "w1:p1", workspace_id: "w1", agent: "pi", agent_status: "working"}
    })

    assert_receive {:jarvis2, "herdr:pane.agent_status_changed",
                    %{
                      delivery: "socket",
                      data: %{"pane_id" => "w1:p1", "agent_status" => "working"}
                    }},
                   1_000

    push(pane, %{event: "pane.output_matched", data: %{pane_id: "w1:p1", matched_line: "FAIL"}})

    assert_receive {:jarvis2, "herdr:pane.output_matched", %{data: %{"matched_line" => "FAIL"}}},
                   1_000

    assert Enum.any?(
             Jarvis2.Journal.recent(source: :herdr),
             &match?(%{type: "pane.output_matched", payload: %{"pane_id" => "w1:p1"}}, &1)
           )
  end

  test "subscription streams read events larger than the default line buffer", %{path: path} do
    stream =
      start_supervised!({Jarvis2.Herdr.EventStream, owner: self(), path: path, subscriptions: []})

    assert_receive {:subscription, socket, _}, 1_000
    assert_receive {:stream_ready, ^stream}, 1_000
    data = %{"pane_id" => "w1:p1", "padding" => String.duplicate("x", 32_768)}
    assert :ok = push(socket, %{event: "pane.updated", data: data})
    assert_receive {:stream_event, ^stream, "pane.updated", ^data}, 1_000
  end

  test "subscription streams reject events above the packet limit", %{path: path} do
    stream =
      start_supervised!(
        {Jarvis2.Herdr.EventStream, owner: self(), path: path, subscriptions: [], retry_ms: 5_000}
      )

    assert_receive {:subscription, socket, _}, 1_000
    assert_receive {:stream_ready, ^stream}, 1_000
    push(socket, %{event: "pane.updated", data: %{padding: String.duplicate("x", 2_097_152)}})
    assert_receive {:stream_down, ^stream, _reason}, 2_000
    refute_receive {:stream_event, ^stream, _, _}, 50
  end

  test "malformed snapshots remain stale and are retried", %{
    fixture: fixture,
    mirror: mirror,
    path: path
  } do
    Agent.update(fixture, &%{&1 | snapshot: Map.put(snapshot(), "agents", ["bad-agent"])})
    start_events(path, mirror)
    assert_receive {:fake_request, "session.snapshot", _}, 1_000
    assert_receive {:fake_request, "session.snapshot", _}, 1_000
    assert Mirror.get(mirror).stale
    Agent.update(fixture, &%{&1 | snapshot: snapshot()})

    eventually(fn ->
      not Mirror.get(mirror).stale and Mirror.get(mirror).snapshot["agents"] == []
    end)
  end

  test "a burst of lifecycle events converges on the latest snapshot", %{
    fixture: fixture,
    mirror: mirror,
    path: path
  } do
    start_events(path, mirror)
    assert_receive {:subscription, lifecycle, _}, 1_000
    eventually(fn -> not Mirror.get(mirror).stale end)
    updated = snapshot() |> Map.put("panes", Enum.map(1..20, &%{"pane_id" => "w1:p#{&1}"}))
    Agent.update(fixture, &%{&1 | snapshot: updated})

    for n <- 1..20 do
      push(lifecycle, %{
        event: "pane_created",
        data: %{type: "pane_created", pane: %{pane_id: "w1:p#{n}"}}
      })
    end

    eventually(fn ->
      not Mirror.get(mirror).stale and length(Mirror.get(mirror).snapshot["panes"]) == 20
    end)
  end

  test "a pane disappearing during subscription causes reconciliation", %{
    fixture: fixture,
    mirror: mirror,
    path: path
  } do
    Agent.update(fixture, &%{&1 | snapshot: snapshot(["w1:p9"]), disappear: true})
    start_events(path, mirror)
    assert_receive {:subscription, _, _}, 1_000

    assert_receive {:fake_request, "events.subscribe",
                    %{"subscriptions" => [%{"pane_id" => "w1:p9"} | _]}},
                   2_000

    eventually(fn ->
      not Mirror.get(mirror).stale and Mirror.get(mirror).snapshot["agents"] == []
    end)
  end

  defp start_events(path, mirror),
    do: start_supervised!({Events, [name: nil, path: path, mirror: mirror, retry_ms: 30]})

  defp snapshot(agent_ids \\ [], worktree \\ false) do
    workspace = %{"workspace_id" => "w1", "label" => "one"}

    workspace =
      if worktree,
        do: Map.put(workspace, "worktree", %{"repo_key" => "repo-key", "repo_root" => "/repo"}),
        else: workspace

    %{
      "version" => "test",
      "protocol" => 22,
      "workspaces" => [workspace],
      "tabs" => [],
      "panes" => Enum.map(agent_ids, &%{"pane_id" => &1, "workspace_id" => "w1"}),
      "layouts" => [],
      "agents" =>
        Enum.map(agent_ids, &%{"pane_id" => &1, "workspace_id" => "w1", "agent_status" => "idle"})
    }
  end

  defp push(socket, value), do: :gen_tcp.send(socket, Jason.encode!(value) <> "\n")

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "condition did not become true"
      Process.sleep(10)
      eventually(fun, deadline)
    end
  end
end
