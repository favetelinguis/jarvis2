defmodule Jarvis2.LayoutDiffTest do
  use ExUnit.Case, async: false
  alias Jarvis2.Herdr.{Mirror, Socket}

  setup do
    snapshot = snapshot()

    {:ok, fixture} =
      start_supervised(
        {Agent,
         fn ->
           %{
             snapshot: snapshot,
             delay: 0,
             worktrees: [%{"path" => "/private/old", "branch" => "private-old"}]
           }
         end}
      )

    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "layout-diff-#{System.unique_integer([:positive])}"
      )

    parent = self()

    handler = fn request ->
      case request["method"] do
        "session.snapshot" ->
          state = Agent.get(fixture, & &1)
          send(parent, {:snapshot_requested, state.snapshot})
          {:later, state.delay, %{result: %{type: "session_snapshot", snapshot: state.snapshot}}}

        "worktree.list" ->
          {:reply, %{result: %{worktrees: Agent.get(fixture, & &1.worktrees)}}}
      end
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
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

    Jarvis2.Bus.subscribe("mirror:layout_diff")
    Mirror.online(mirror, ["w1:p1"])

    assert_receive {:jarvis2, "mirror:layout_diff",
                    %{source: ^mirror, diff: %{status: "baseline", sequence: 1, changes: []}}},
                   1_000

    %{fixture: fixture, mirror: mirror, snapshot: snapshot}
  end

  test "emits detailed layout, geometry, split, focus and agent diffs without private labels",
       ctx do
    updated =
      ctx.snapshot
      |> put_in(["panes"], [pane("w1:p1"), pane("w1:p2")])
      |> put_in(["agents", Access.at(0), "agent_status"], "working")
      |> put_in(["focused_pane_id"], "w1:p2")
      |> put_in(["layouts", Access.at(0), "focused_pane_id"], "w1:p2")
      |> put_in(["layouts", Access.at(0), "panes"], [geometry("w1:p1", 40), geometry("w1:p2", 40)])
      |> put_in(["layouts", Access.at(0), "splits"], [split(0.55)])

    diff = refresh(ctx, updated)
    assert diff.status == "changed" and diff.sequence == 2 and not diff.truncated
    assert Enum.any?(diff.changes, &match?(%{kind: "pane", id: "w1:p2", change: "added"}, &1))

    assert Enum.any?(
             diff.changes,
             &match?(
               %{kind: "focus", before: %{pane_id: "w1:p1"}, after: %{pane_id: "w1:p2"}},
               &1
             )
           )

    assert Enum.any?(
             diff.changes,
             &match?(
               %{
                 kind: "geometry",
                 tab_id: "w1:t1",
                 pane_id: "w1:p1",
                 before: %{width: 80},
                 after: %{width: 40}
               },
               &1
             )
           )

    assert Enum.any?(
             diff.changes,
             &match?(
               %{
                 kind: "split",
                 tab_id: "w1:t1",
                 id: "split-1",
                 change: "added",
                 after: %{ratio: 0.55}
               },
               &1
             )
           )

    assert Enum.any?(
             diff.changes,
             &match?(
               %{
                 kind: "agent",
                 id: "w1:p1",
                 before: %{status: "idle"},
                 after: %{status: "working"}
               },
               &1
             )
           )

    refute inspect(diff) =~ "private-"
    assert Mirror.get(ctx.mirror).layout_diff == diff
  end

  test "reports the old and new parents when a pane moves", ctx do
    updated = ctx.snapshot |> put_in(["panes", Access.at(0), "tab_id"], "w1:t2")
    diff = refresh(ctx, updated)

    assert Enum.any?(
             diff.changes,
             &match?(
               %{
                 kind: "pane",
                 id: "w1:p1",
                 change: "updated",
                 fields: ["tab_id"],
                 before: %{tab_id: "w1:t1"},
                 after: %{tab_id: "w1:t2"}
               },
               &1
             )
           )
  end

  test "detects ratio and zoom changes and coalesces reordered or irrelevant metadata", ctx do
    first = ctx.snapshot |> put_in(["layouts", Access.at(0), "splits"], [split(0.55)])
    refresh(ctx, first)

    second =
      first
      |> put_in(["layouts", Access.at(0), "splits", Access.at(0), "ratio"], 0.65)
      |> put_in(["layouts", Access.at(0), "zoomed"], true)

    diff = refresh(ctx, second)

    assert Enum.any?(
             diff.changes,
             &match?(
               %{kind: "split", change: "updated", before: %{ratio: 0.55}, after: %{ratio: 0.65}},
               &1
             )
           )

    assert Enum.any?(
             diff.changes,
             fn change ->
               match?(%{kind: "layout", id: "w1:t1"}, change) and "zoomed" in change.fields
             end
           )

    noop =
      second
      |> put_in(["panes", Access.at(0), "cwd"], "/private/another")
      |> put_in(["panes", Access.at(0), "revision"], 99)

    Agent.update(ctx.fixture, &%{&1 | snapshot: noop})
    Mirror.invalidate(ctx.mirror)
    assert_receive {:snapshot_requested, ^noop}, 1_000
    eventually(fn -> not Mirror.get(ctx.mirror).stale end)
    mirror = ctx.mirror
    refute_receive {:jarvis2, "mirror:layout_diff", %{source: ^mirror}}, 100
    assert Mirror.get(ctx.mirror).layout_diff.sequence == diff.sequence
  end

  test "ignores ordering changes in snapshot lists", ctx do
    first =
      ctx.snapshot
      |> put_in(["panes"], [pane("w1:p1"), pane("w1:p2")])
      |> put_in(["layouts", Access.at(0), "panes"], [geometry("w1:p1", 40), geometry("w1:p2", 40)])

    refresh(ctx, first)

    reordered =
      first
      |> update_in(["panes"], &Enum.reverse/1)
      |> update_in(["layouts", Access.at(0), "panes"], &Enum.reverse/1)

    Agent.update(ctx.fixture, &%{&1 | snapshot: reordered})
    Mirror.invalidate(ctx.mirror)
    assert_receive {:snapshot_requested, ^reordered}, 1_000
    eventually(fn -> not Mirror.get(ctx.mirror).stale end)
    mirror = ctx.mirror
    refute_receive {:jarvis2, "mirror:layout_diff", %{source: ^mirror}}, 100
  end

  test "reports net changes after reconnect without claiming complete history", ctx do
    Mirror.offline(ctx.mirror)
    updated = put_in(ctx.snapshot, ["focused_pane_id"], nil)
    Agent.update(ctx.fixture, &%{&1 | snapshot: updated})
    Mirror.online(ctx.mirror, ["w1:p1"])
    mirror = ctx.mirror
    assert_receive {:jarvis2, "mirror:layout_diff", %{source: ^mirror, diff: diff}}, 1_000
    assert diff.status == "resynced" and diff.sequence == 2
    assert Enum.any?(diff.changes, &match?(%{kind: "focus"}, &1))
    Mirror.offline(mirror)
    Mirror.online(mirror, ["w1:p1"])

    assert_receive {:jarvis2, "mirror:layout_diff",
                    %{source: ^mirror, diff: %{status: "resynced", changes: []}}},
                   1_000
  end

  test "does not use an intermediate dirty snapshot as the diff baseline", ctx do
    first = put_in(ctx.snapshot, ["focused_pane_id"], "w1:p2")
    Agent.update(ctx.fixture, &%{&1 | snapshot: first, delay: 150})
    Mirror.invalidate(ctx.mirror)
    assert_receive {:snapshot_requested, ^first}, 1_000
    final = put_in(ctx.snapshot, ["focused_pane_id"], nil)
    Agent.update(ctx.fixture, &%{&1 | snapshot: final, delay: 0})
    Mirror.invalidate(ctx.mirror)
    mirror = ctx.mirror
    assert_receive {:jarvis2, "mirror:layout_diff", %{source: ^mirror, diff: diff}}, 2_000

    assert Enum.any?(
             diff.changes,
             &match?(%{kind: "focus", before: %{pane_id: "w1:p1"}, after: %{pane_id: nil}}, &1)
           )

    refute_receive {:jarvis2, "mirror:layout_diff", %{source: ^mirror}}, 100
  end

  test "bounds large diffs and marks truncation", ctx do
    updated = put_in(ctx.snapshot, ["panes"], Enum.map(1..150, &pane("w1:p#{&1}")))
    diff = refresh(ctx, updated)
    assert diff.truncated
    assert length(diff.changes) == 64
    assert Enum.all?(diff.changes, &(&1.kind == "pane"))
  end

  test "oversized projections are unavailable instead of returning a partial baseline", ctx do
    oversized = put_in(ctx.snapshot, ["panes"], Enum.map(1..2_049, &pane("w1:p#{&1}")))
    Agent.update(ctx.fixture, &%{&1 | snapshot: oversized})
    Mirror.invalidate(ctx.mirror)
    mirror = ctx.mirror

    assert_receive {:jarvis2, "mirror:layout_diff",
                    %{source: ^mirror, diff: %{status: "unavailable", changes: []}}},
                   2_000

    assert Mirror.get(mirror).layout_diff.status == "unavailable"
  end

  test "marks malformed projections unavailable and resyncs from the last good baseline", ctx do
    bad = put_in(ctx.snapshot, ["panes"], [pane("w1:p1"), pane("w1:p1")])
    Agent.update(ctx.fixture, &%{&1 | snapshot: bad})
    Mirror.invalidate(ctx.mirror)
    mirror = ctx.mirror

    assert_receive {:jarvis2, "mirror:layout_diff",
                    %{source: ^mirror, diff: %{status: "unavailable", changes: []}}},
                   1_000

    fixed = put_in(ctx.snapshot, ["focused_pane_id"], nil)
    diff = refresh(ctx, fixed)
    assert diff.status == "resynced"

    assert Enum.any?(
             diff.changes,
             &match?(%{kind: "focus", before: %{pane_id: "w1:p1"}, after: %{pane_id: nil}}, &1)
           )
  end

  test "a null layout area is unavailable instead of being reported as a geometry change", ctx do
    invalid = put_in(ctx.snapshot, ["layouts", Access.at(0), "area"], nil)
    Agent.update(ctx.fixture, &%{&1 | snapshot: invalid})
    Mirror.invalidate(ctx.mirror)
    mirror = ctx.mirror

    assert_receive {:jarvis2, "mirror:layout_diff",
                    %{source: ^mirror, diff: %{status: "unavailable", changes: []}}},
                   1_000
  end

  test "malformed geometry is unavailable instead of being reported as a removal", ctx do
    invalid = put_in(ctx.snapshot, ["layouts", Access.at(0), "panes", Access.at(0), "rect"], nil)
    Agent.update(ctx.fixture, &%{&1 | snapshot: invalid})
    Mirror.invalidate(ctx.mirror)
    mirror = ctx.mirror

    assert_receive {:jarvis2, "mirror:layout_diff",
                    %{source: ^mirror, diff: %{status: "unavailable", changes: []}}},
                   1_000
  end

  test "logs only diff metadata, not labels or paths", ctx do
    changed = put_in(ctx.snapshot, ["panes", Access.at(0), "label"], "private-new-label")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        diff = refresh(ctx, changed)
        assert Enum.any?(diff.changes, &match?(%{kind: "pane", fields: ["label"]}, &1))
        refute inspect(diff) =~ "private-new-label"
      end)

    assert log =~ "Herdr layout diff status=changed"
    refute log =~ "private-new-label"
    refute log =~ "/private/"
  end

  test "ignores worktree list reordering", ctx do
    snapshot =
      put_in(ctx.snapshot, ["workspaces", Access.at(0), "worktree"], %{
        "repo_key" => "repo",
        "repo_root" => "/private/repo"
      })

    trees = [
      %{"path" => "/private/a", "branch" => "a"},
      %{"path" => "/private/b", "branch" => "b"}
    ]

    Agent.update(ctx.fixture, &%{&1 | worktrees: trees})
    refresh(ctx, snapshot)
    assert_receive {:snapshot_requested, ^snapshot}, 1_000
    Agent.update(ctx.fixture, &%{&1 | worktrees: Enum.reverse(trees)})
    Mirror.invalidate(ctx.mirror)
    assert_receive {:snapshot_requested, ^snapshot}, 1_000
    eventually(fn -> not Mirror.get(ctx.mirror).stale end)
    mirror = ctx.mirror
    refute_receive {:jarvis2, "mirror:layout_diff", %{source: ^mirror}}, 100
  end

  test "reports worktree changes without revealing checkout paths", ctx do
    with_repo =
      put_in(ctx.snapshot, ["workspaces", Access.at(0), "worktree"], %{
        "repo_key" => "private-repo",
        "repo_root" => "/private/repo"
      })

    first = refresh(ctx, with_repo)
    assert Enum.any?(first.changes, &match?(%{kind: "worktrees"}, &1))

    Agent.update(
      ctx.fixture,
      &%{&1 | worktrees: [%{"path" => "/private/new", "branch" => "private-new"}]}
    )

    Mirror.invalidate(ctx.mirror)
    mirror = ctx.mirror
    assert_receive {:jarvis2, "mirror:layout_diff", %{source: ^mirror, diff: diff}}, 1_000
    assert Enum.any?(diff.changes, &match?(%{kind: "worktrees"}, &1))
    refute inspect(diff) =~ "private-"
    refute inspect(diff) =~ "/private/"
  end

  defp refresh(ctx, snapshot) do
    Agent.update(ctx.fixture, &%{&1 | snapshot: snapshot})
    Mirror.invalidate(ctx.mirror)
    mirror = ctx.mirror
    assert_receive {:jarvis2, "mirror:layout_diff", %{source: ^mirror, diff: diff}}, 2_000
    diff
  end

  defp snapshot do
    %{
      "workspaces" => [%{"workspace_id" => "w1", "label" => "private-workspace"}],
      "tabs" => [%{"workspace_id" => "w1", "tab_id" => "w1:t1", "label" => "private-tab"}],
      "panes" => [pane("w1:p1")],
      "agents" => [
        %{
          "workspace_id" => "w1",
          "tab_id" => "w1:t1",
          "pane_id" => "w1:p1",
          "agent" => "pi",
          "name" => "private-agent",
          "agent_status" => "idle"
        }
      ],
      "layouts" => [
        %{
          "workspace_id" => "w1",
          "tab_id" => "w1:t1",
          "zoomed" => false,
          "focused_pane_id" => "w1:p1",
          "area" => rect(80),
          "panes" => [geometry("w1:p1", 80)],
          "splits" => []
        }
      ],
      "focused_workspace_id" => "w1",
      "focused_tab_id" => "w1:t1",
      "focused_pane_id" => "w1:p1"
    }
  end

  defp pane(id),
    do: %{
      "pane_id" => id,
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "label" => "private-pane",
      "cwd" => "/private/path"
    }

  defp geometry(id, width),
    do: %{"pane_id" => id, "rect" => rect(width), "focused" => id == "w1:p1"}

  defp rect(width), do: %{"x" => 0, "y" => 0, "width" => width, "height" => 25}

  defp split(ratio),
    do: %{"id" => "split-1", "direction" => "right", "ratio" => ratio, "rect" => rect(80)}

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    if fun.(),
      do: :ok,
      else:
        (
          assert System.monotonic_time(:millisecond) < deadline
          Process.sleep(10)
          eventually(fun, deadline)
        )
  end
end
