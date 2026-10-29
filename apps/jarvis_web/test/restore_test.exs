defmodule Jarvis2.RestoreTest do
  use ExUnit.Case, async: false

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
    def handle_call({:put, view}, _from, _), do: {:reply, :ok, view}
  end

  setup do
    dir =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "restore-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "herdr.sock")
    parent = self()

    failures = start_supervised!({Agent, fn -> false end})

    handler = fn request ->
      send(parent, {:write, request})

      case Agent.get(failures, & &1) do
        true -> {:reply, %{error: %{code: "failed", message: "private"}}}
        {:delay, ms} -> {:later, ms, %{result: %{type: "ok"}}}
        false -> {:reply, %{result: %{type: "ok"}}}
      end
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    socket = start_supervised!({Jarvis2.Herdr.Socket, [name: nil, path: path]})

    pane = %{
      "pane_id" => "w1:p1",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "terminal_id" => "t1",
      "cwd" => File.cwd!()
    }

    agent = Map.merge(pane, %{"name" => "worker", "agent" => "pi", "agent_status" => "working"})
    view = %{stale: false, snapshot: %{"panes" => [pane], "agents" => [agent]}}
    mirror = start_supervised!({Mirror, view})
    replace_config(:mirror, mirror)
    replace_config(:herdr_socket, socket)
    replace_config(:live, true)
    replace_config(:live_scenarios, [:sidebar_tokens])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(dir)
    end)

    %{dir: dir, path: path, mirror: mirror, socket: socket, view: view, failures: failures}
  end

  test "restores an unexpired status token only to the same terminal", ctx do
    restore = start_restore(ctx, :first)
    replace_config(:restore, restore)

    caller =
      Jarvis2.MCP.Identity.resolve(
        %{"x-herdr-pane" => "w1:p1", "x-herdr-workspace" => "w1"},
        ctx.view
      )

    assert {:ok, _} =
             Jarvis2.MCP.Tools.call(
               "report_status",
               %{state: "working", summary: "private summary"},
               caller
             )

    assert_receive {:write, %{"method" => "pane.report_metadata"}}, 1_000
    GenServer.stop(restore)
    file = Path.join(ctx.dir, "restore.json")
    legacy = file |> File.read!() |> Jason.decode!() |> Map.put("focus", true)
    File.write!(file, Jason.encode!(legacy))
    second = start_restore(ctx, :second)
    publish_fresh(ctx)
    assert_receive {:write, %{"method" => "pane.report_metadata", "params" => params}}, 1_000
    assert params["pane_id"] == "w1:p1"
    assert params["tokens"]["jarvis"] == "working: private summary"
    assert params["ttl_ms"] in 1..60_000
    GenServer.stop(second)

    changed =
      put_in(ctx.view.snapshot["panes"], [
        Map.put(hd(ctx.view.snapshot["panes"]), "terminal_id", "replacement")
      ])

    GenServer.call(ctx.mirror, {:put, changed})
    start_restore(ctx, :third)
    publish_fresh(ctx)
    refute_receive {:write, %{"method" => "pane.report_metadata"}}, 150
  end

  test "status and workspace tokens are restored without extending their lifetime", ctx do
    restore = start_restore(ctx, :first)
    replace_config(:restore, restore)

    presentation =
      start_supervised!(
        {Jarvis2.Scenarios.Presentation,
         [name: nil, socket: ctx.socket, mirror: ctx.mirror, debounce_ms: 1]}
      )

    caller =
      Jarvis2.MCP.Identity.resolve(
        %{"x-herdr-pane" => "w1:p1", "x-herdr-workspace" => "w1"},
        ctx.view
      )

    Jarvis2.Bus.publish("mcp:tool_call", %{caller: caller, tool: "whoami"})

    Jarvis2.Bus.publish("herdr:pane.agent_status_changed", %{
      data: %{
        "pane_id" => "w1:p1",
        "workspace_id" => "w1",
        "agent" => "pi",
        "agent_status" => "working"
      }
    })

    assert_receive {:write, %{"method" => "workspace.report_metadata"}}, 1_000
    assert_receive {:write, %{"method" => "pane.report_metadata"}}, 1_000
    :sys.get_state(presentation)
    GenServer.stop(restore)
    start_restore(ctx, :second)
    publish_fresh(ctx)

    assert_receive {:write, %{"method" => "workspace.report_metadata", "params" => workspace}},
                   1_000

    assert_receive {:write, %{"method" => "pane.report_metadata", "params" => pane}}, 1_000
    assert workspace["tokens"] == %{"last_tool" => "whoami"}
    assert pane["tokens"] == %{"agent_state" => "working"}
    assert workspace["ttl_ms"] in 1..60_000 and pane["ttl_ms"] in 1..60_000
  end

  test "each restored token rechecks the mirror after preceding writes", ctx do
    restore = start_restore(ctx, :first)
    replace_config(:restore, restore)

    presentation =
      start_supervised!(
        {Jarvis2.Scenarios.Presentation,
         [name: nil, socket: ctx.socket, mirror: ctx.mirror, debounce_ms: 1]}
      )

    caller =
      Jarvis2.MCP.Identity.resolve(
        %{"x-herdr-pane" => "w1:p1", "x-herdr-workspace" => "w1"},
        ctx.view
      )

    Jarvis2.Bus.publish("mcp:tool_call", %{caller: caller, tool: "whoami"})

    Jarvis2.Bus.publish("herdr:pane.agent_status_changed", %{
      data: %{
        "pane_id" => "w1:p1",
        "workspace_id" => "w1",
        "agent" => "pi",
        "agent_status" => "working"
      }
    })

    assert_receive {:write, %{"method" => "workspace.report_metadata"}}, 1_000
    assert_receive {:write, %{"method" => "pane.report_metadata"}}, 1_000
    :sys.get_state(presentation)
    GenServer.stop(restore)
    Agent.update(ctx.failures, fn _ -> {:delay, 150} end)
    second = start_restore(ctx, :second)
    publish_fresh(ctx)
    assert_receive {:write, %{"method" => first}}, 1_000
    assert first in ["workspace.report_metadata", "pane.report_metadata"]
    GenServer.call(ctx.mirror, {:put, %{ctx.view | stale: true}})
    :sys.get_state(second)
    refute_receive {:write, %{"method" => _}}, 200
    GenServer.call(ctx.mirror, {:put, ctx.view})
    publish_fresh(ctx)
    assert_receive {:write, %{"method" => other}}, 1_000
    refute other == first
  end

  test "permissive or malformed saved token files are ignored", ctx do
    restore = start_restore(ctx, :first)
    replace_config(:restore, restore)

    caller =
      Jarvis2.MCP.Identity.resolve(
        %{"x-herdr-pane" => "w1:p1", "x-herdr-workspace" => "w1"},
        ctx.view
      )

    assert {:ok, _} =
             Jarvis2.MCP.Tools.call("report_status", %{state: "done", summary: "private"}, caller)

    assert_receive {:write, %{"method" => "pane.report_metadata"}}, 1_000
    GenServer.stop(restore)

    file = Path.join(ctx.dir, "restore.json")
    assert Bitwise.band(File.stat!(file).mode, 0o077) == 0
    File.chmod!(file, 0o644)
    second = start_restore(ctx, :second)
    publish_fresh(ctx)
    refute_receive {:write, %{"method" => "pane.report_metadata"}}, 150
    GenServer.stop(second)
    File.chmod!(file, 0o600)
    File.write!(file, "{malformed")
    start_restore(ctx, :third)
    publish_fresh(ctx)
    refute_receive {:write, %{"method" => "pane.report_metadata"}}, 150
  end

  test "expired tokens and changed agents are not restored", ctx do
    restore = start_restore(ctx, :first)
    replace_config(:restore, restore)

    caller =
      Jarvis2.MCP.Identity.resolve(
        %{"x-herdr-pane" => "w1:p1", "x-herdr-workspace" => "w1"},
        ctx.view
      )

    assert {:ok, _} =
             Jarvis2.MCP.Tools.call("report_status", %{state: "done", summary: "secret"}, caller)

    assert_receive {:write, %{"method" => "pane.report_metadata"}}, 1_000
    GenServer.stop(restore)
    file = Path.join(ctx.dir, "restore.json")
    original = File.read!(file) |> Jason.decode!()

    expired =
      update_in(original["tokens"], fn entries ->
        Enum.map(entries, &Map.put(&1, "expires_at", System.system_time(:millisecond) - 1))
      end)

    File.write!(file, Jason.encode!(expired))
    second = start_restore(ctx, :second)
    publish_fresh(ctx)
    refute_receive {:write, %{"method" => "pane.report_metadata"}}, 150
    GenServer.stop(second)
    File.write!(file, Jason.encode!(original))

    changed =
      put_in(ctx.view.snapshot["agents"], [
        Map.put(hd(ctx.view.snapshot["agents"]), "name", "different")
      ])

    GenServer.call(ctx.mirror, {:put, changed})
    start_restore(ctx, :third)
    publish_fresh(ctx)
    refute_receive {:write, %{"method" => "pane.report_metadata"}}, 150
  end

  test "expired token values are removed from the private state file", ctx do
    restore = start_restore(ctx, :first)
    replace_config(:restore, restore)

    caller =
      Jarvis2.MCP.Identity.resolve(
        %{"x-herdr-pane" => "w1:p1", "x-herdr-workspace" => "w1"},
        ctx.view
      )

    assert {:ok, _} =
             Jarvis2.MCP.Tools.call(
               "report_status",
               %{state: "done", summary: "ephemeral secret"},
               caller
             )

    assert_receive {:write, %{"method" => "pane.report_metadata"}}, 1_000
    GenServer.stop(restore)
    file = Path.join(ctx.dir, "restore.json")

    data =
      File.read!(file)
      |> Jason.decode!()
      |> update_in(["tokens"], fn entries ->
        Enum.map(entries, &Map.put(&1, "expires_at", System.system_time(:millisecond) + 250))
      end)

    File.write!(file, Jason.encode!(data))
    second = start_restore(ctx, :second)
    Process.sleep(400)
    :sys.get_state(second)
    contents = File.read!(file)
    assert Jason.decode!(contents)["tokens"] == []
    refute contents =~ "ephemeral secret"
  end

  test "a failed restore is not retried in the same process", ctx do
    restore = start_restore(ctx, :first)
    replace_config(:restore, restore)

    caller =
      Jarvis2.MCP.Identity.resolve(
        %{"x-herdr-pane" => "w1:p1", "x-herdr-workspace" => "w1"},
        ctx.view
      )

    assert {:ok, _} =
             Jarvis2.MCP.Tools.call("report_status", %{state: "done", summary: "private"}, caller)

    assert_receive {:write, %{"method" => "pane.report_metadata"}}, 1_000
    GenServer.stop(restore)
    Agent.update(ctx.failures, fn _ -> true end)
    second = start_restore(ctx, :second)
    publish_fresh(ctx)
    assert_receive {:write, %{"method" => "pane.report_metadata"}}, 1_000
    :sys.get_state(second)
    publish_fresh(ctx)
    refute_receive {:write, %{"method" => "pane.report_metadata"}}, 150
  end

  defp start_restore(ctx, id) do
    start_supervised!(
      Supervisor.child_spec(
        {Jarvis2.Scenarios.Restore,
         [
           name: nil,
           state_dir: ctx.dir,
           socket_path: ctx.path,
           mirror: ctx.mirror,
           socket: ctx.socket
         ]},
        id: id,
        restart: :temporary
      )
    )
  end

  defp publish_fresh(ctx),
    do: Jarvis2.Bus.publish("mirror:updated", %{source: ctx.mirror, view: %{stale: false}})

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
