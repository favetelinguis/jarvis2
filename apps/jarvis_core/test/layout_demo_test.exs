defmodule Jarvis2.LayoutDemoTest do
  use ExUnit.Case, async: false
  alias Jarvis2.Herdr.Socket
  alias Jarvis2.Layouts.Dev, as: LayoutDev

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
  end

  setup do
    view = %{
      stale: false,
      snapshot: %{
        "workspaces" => [%{"workspace_id" => "w1"}],
        "tabs" => [%{"workspace_id" => "w1", "tab_id" => "w1:t1"}],
        "panes" => [
          %{
            "workspace_id" => "w1",
            "tab_id" => "w1:t1",
            "pane_id" => "w1:p1",
            "cwd" => File.cwd!()
          }
        ],
        "agents" => []
      }
    }

    {:ok, mirror} = start_supervised({Mirror, view})
    {:ok, behavior} = start_supervised({Agent, fn -> :normal end})
    parent = self()

    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "layout-demo-#{System.unique_integer([:positive])}"
      )

    handler = fn request ->
      send(parent, {:request, request})
      mode = Agent.get(behavior, & &1)
      respond(request, mode)
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Socket, [name: nil, path: path]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    config(:mirror, mirror)
    config(:herdr_socket, socket)
    config(:live, true)
    config(:live_scenarios, [:declarative_layout])
    %{behavior: behavior}
  end

  test "dry run describes the demo without sending requests" do
    Application.put_env(:jarvis2, :live, false)

    assert {:ok,
            %{
              dry_run: true,
              root: root,
              demo: %{status: "planned", initial_ratio: 0.55, final_ratio: 0.65}
            }} = create()

    assert root.ratio == 0.55
    refute_receive {:request, _}, 100
  end

  test "exports the newly-created tab and changes only its root split" do
    assert {:ok,
            %{
              "type" => "layout_apply",
              "layout" => %{"root" => %{"ratio" => 0.65}},
              "demo" => %{status: "complete", tab_id: "w1:t2", root_ratio: 0.65}
            }} = create()

    assert_receive {:request, %{"method" => "layout.apply", "params" => apply}}, 1_000
    assert apply["workspace_id"] == "w1" and apply["focus"] == false
    refute Map.has_key?(apply, "tab_id")
    assert apply["root"]["ratio"] == 0.55

    assert_receive {:request, %{"method" => "layout.export", "params" => %{"tab_id" => "w1:t2"}}},
                   1_000

    assert_receive {:request,
                    %{
                      "method" => "layout.set_split_ratio",
                      "params" => %{"tab_id" => "w1:t2", "path" => [], "ratio" => 0.65}
                    }},
                   1_000

    refute_receive {:request, _}, 100
  end

  test "never adjusts an existing tab or reuses an existing pane", %{behavior: behavior} do
    for mode <- [:existing_tab, :reused_pane, :foreign_workspace] do
      Agent.update(behavior, fn _ -> mode end)
      assert {:ok, %{"demo" => %{status: "skipped", reason: "unsafe_create_response"}}} = create()
      assert_receive {:request, %{"method" => "layout.apply"}}, 1_000
      refute_receive {:request, _}, 50
    end
  end

  test "does not resize if exported layout changed, is zoomed, or cannot be read", %{
    behavior: behavior
  } do
    for mode <- [:changed_export, :zoomed_export, :export_error] do
      Agent.update(behavior, fn _ -> mode end)
      assert {:ok, %{"demo" => %{status: "skipped"}}} = create()
      assert_receive {:request, %{"method" => "layout.apply"}}, 1_000
      assert_receive {:request, %{"method" => "layout.export"}}, 1_000
      refute_receive {:request, _}, 50
    end
  end

  test "disabling live mode between creation and ratio update prevents the second write", %{
    behavior: behavior
  } do
    Agent.update(behavior, fn _ -> :disable_live end)

    assert {:ok, %{"demo" => %{status: "skipped", reason: "live_disabled", tab_id: "w1:t2"}}} =
             create()

    assert_receive {:request, %{"method" => "layout.apply"}}, 1_000
    assert_receive {:request, %{"method" => "layout.export"}}, 1_000
    refute_receive {:request, _}, 100
  end

  test "an uncertain apply warns not to retry; no export or second apply is sent", %{
    behavior: behavior
  } do
    Agent.update(behavior, fn _ -> :apply_disconnected end)
    assert {:error, message} = create()
    assert message =~ "may have been created"
    assert_receive {:request, %{"method" => "layout.apply"}}, 1_000
    refute_receive {:request, _}, 100
  end

  test "a Herdr apply error does not claim creation was rolled back", %{behavior: behavior} do
    Agent.update(behavior, fn _ -> :apply_error end)
    assert {:error, message} = create()
    assert message =~ "may have been created"
    assert_receive {:request, %{"method" => "layout.apply"}}, 1_000
    refute_receive {:request, _}, 100
  end

  test "an invalid apply response is also treated as uncertain", %{behavior: behavior} do
    Agent.update(behavior, fn _ -> :apply_invalid_response end)
    assert {:error, message} = create()
    assert message =~ "may have been created"
    assert_receive {:request, %{"method" => "layout.apply"}}, 1_000
    refute_receive {:request, _}, 100
  end

  test "an unrecognized apply result warns that creation may have happened", %{behavior: behavior} do
    Agent.update(behavior, fn _ -> :apply_invalid_type end)
    assert {:error, message} = create()
    assert message =~ "may have been created"
    assert_receive {:request, %{"method" => "layout.apply"}}, 1_000
    refute_receive {:request, _}, 100
  end

  test "a dropped export connection after creation still returns the new tab", %{
    behavior: behavior
  } do
    Agent.update(behavior, fn _ -> :socket_crash_export end)

    assert {:ok, %{"type" => "layout_apply", "demo" => %{status: "skipped", tab_id: "w1:t2"}}} =
             create()

    assert_receive {:request, %{"method" => "layout.apply"}}, 1_000
    assert_receive {:request, %{"method" => "layout.export"}}, 1_000
    refute_receive {:request, _}, 100
  end

  test "an uncertain ratio update returns the created tab and is not retried", %{
    behavior: behavior
  } do
    Agent.update(behavior, fn _ -> :ratio_disconnected end)

    assert {:ok, %{"type" => "layout_apply", "demo" => %{status: "unconfirmed", tab_id: "w1:t2"}}} =
             create()

    assert_receive {:request, %{"method" => "layout.apply"}}, 1_000
    assert_receive {:request, %{"method" => "layout.export"}}, 1_000
    assert_receive {:request, %{"method" => "layout.set_split_ratio"}}, 1_000
    refute_receive {:request, _}, 150
  end

  defp create, do: LayoutDev.create("dev", %{pane: "w1:p1", workspace: "w1"})

  defp respond(%{"method" => "layout.apply"}, :apply_disconnected), do: :close

  defp respond(%{"method" => "layout.apply"}, :apply_error),
    do: {:reply, %{error: %{code: "internal_error", message: "unknown"}}}

  defp respond(%{"method" => "layout.apply"}, :apply_invalid_response),
    do: {:reply, %{unexpected: true}}

  defp respond(%{"method" => "layout.apply"}, :apply_invalid_type),
    do: {:reply, %{result: %{type: "unexpected"}}}

  defp respond(%{"method" => "layout.apply", "params" => %{"root" => root}}, mode) do
    root =
      root
      |> put_in(["first", "pane_id"], if(mode == :reused_pane, do: "w1:p1", else: "w1:p2"))
      |> put_in(["second", "first", "pane_id"], "w1:p3")
      |> put_in(["second", "second", "pane_id"], "w1:p4")

    layout = %{
      "workspace_id" => if(mode == :foreign_workspace, do: "w2", else: "w1"),
      "tab_id" => if(mode == :existing_tab, do: "w1:t1", else: "w1:t2"),
      "zoomed" => false,
      "focused_pane_id" => "w1:p2",
      "root" => root
    }

    {:reply, %{result: %{type: "layout_apply", layout: layout}}}
  end

  defp respond(%{"method" => "layout.export"}, :disable_live) do
    Application.put_env(:jarvis2, :live, false)
    respond(%{"method" => "layout.export"}, :normal)
  end

  defp respond(%{"method" => "layout.export"}, :socket_crash_export), do: :close

  defp respond(%{"method" => "layout.export"}, :export_error),
    do: {:reply, %{error: %{code: "not_found", message: "gone"}}}

  defp respond(%{"method" => "layout.export"}, mode) do
    root = %{
      "type" => "split",
      "direction" => "right",
      "ratio" => 0.55,
      "first" => leaf("w1:p2", "editor"),
      "second" => %{
        "type" => "split",
        "direction" => "down",
        "ratio" => 0.5,
        "first" => leaf("w1:p3", if(mode == :changed_export, do: "changed", else: "tests")),
        "second" => leaf("w1:p4", "agent")
      }
    }

    layout = %{
      "workspace_id" => "w1",
      "tab_id" => "w1:t2",
      "zoomed" => mode == :zoomed_export,
      "focused_pane_id" => "w1:p2",
      "root" => root
    }

    {:reply, %{result: %{type: "layout_export", layout: layout}}}
  end

  defp respond(%{"method" => "layout.set_split_ratio"}, :ratio_disconnected), do: :close

  defp respond(%{"method" => "layout.set_split_ratio"}, _mode) do
    {:reply, %{result: %{layout: layout}}} = respond(%{"method" => "layout.export"}, :normal)
    layout = put_in(layout, ["root", "ratio"], 0.65)
    {:reply, %{result: %{type: "layout_split_ratio_set", layout: layout}}}
  end

  defp leaf(id, label),
    do: %{"type" => "pane", "pane_id" => id, "label" => label, "cwd" => File.cwd!()}

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
