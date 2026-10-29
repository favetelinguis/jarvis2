defmodule Jarvis2.ScenariosTest do
  use ExUnit.Case, async: false

  alias Jarvis2.Herdr.Socket
  alias Jarvis2.Scenarios.{Attention, Dashboard, OutputWatcher, FocusMode, LayoutDev}

  defmodule StaticMirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
  end

  setup do
    previous_live = Application.get_env(:jarvis2, :live, false)
    previous_scenarios = Application.get_env(:jarvis2, :live_scenarios, [])
    Application.put_env(:jarvis2, :live, false)
    Application.put_env(:jarvis2, :live_scenarios, [])

    on_exit(fn ->
      Application.put_env(:jarvis2, :live, previous_live)
      Application.put_env(:jarvis2, :live_scenarios, previous_scenarios)
    end)

    :ok
  end

  test "output watcher logs metadata without exposing the matched line in dry mode" do
    start_supervised!({OutputWatcher, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:output_watcher")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Jarvis2.Bus.publish("herdr:pane.output_matched", %{
          type: "pane.output_matched",
          data: %{"pane_id" => "w1:p1", "matched_line" => "FAIL token=private-value"}
        })

        assert_receive {:jarvis2, "scenario:output_watcher", %{pane: "w1:p1", dry_run: true}},
                       1_000
      end)

    assert log =~ "would call"
    assert log =~ "pane=\"w1:p1\""
    refute log =~ "private-value"
  end

  test "attention notifies once for a transition and clears on focus" do
    start_supervised!({Attention, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:attention")

    status = %{
      type: "pane.agent_status_changed",
      data: %{"pane_id" => "w1:p1", "agent_status" => "blocked", "agent" => "pi"}
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Jarvis2.Bus.publish("herdr:pane.agent_status_changed", status)
        assert_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "blocked"}}, 1_000
        Jarvis2.Bus.publish("herdr:pane.agent_status_changed", status)
        refute_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "blocked"}}, 50

        Jarvis2.Bus.publish("herdr:pane.focused", %{
          type: "pane.focused",
          data: %{"pane_id" => "w1:p1"}
        })

        assert_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "cleared"}}, 1_000
      end)

    assert log =~ "notification.show"
    assert log =~ "client.window_title.set"
    assert log =~ "client.window_title.clear"
  end

  test "dashboard hook opens the popup with the app's port and state path" do
    {socket, listener, path} = fake_socket()

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    Application.put_env(:jarvis2, :live, true)
    Application.put_env(:jarvis2, :live_scenarios, [:dashboard])
    start_supervised!({Dashboard, [name: nil, socket: socket]})
    Jarvis2.Bus.subscribe("scenario:dashboard")

    Jarvis2.Web.Hooks.accept("action", "open-dashboard", %{
      "context" => %{"focused_pane_id" => "w1:p1"}
    })

    assert_receive {:herdr_write, %{"method" => "plugin.pane.open", "params" => params}}, 1_000
    assert params["plugin_id"] == "favetelinguis.jarvis2" and params["entrypoint"] == "dashboard"

    assert params["placement"] == "popup" and params["width"] == "80%" and
             params["height"] == "80%"

    assert params["env"]["JARVIS2_DASHBOARD_STATE_DIR"] ==
             Application.fetch_env!(:jarvis2, :state_dir)

    assert_receive {:jarvis2, "scenario:dashboard", %{outcome: :ok}}, 1_000
  end

  test "focus-mode hooks set and clear only this plugin's view" do
    {socket, listener, path} = fake_socket()

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    Application.put_env(:jarvis2, :live, true)
    Application.put_env(:jarvis2, :live_scenarios, [:focus_mode])
    start_supervised!({FocusMode, [name: nil, socket: socket]})
    Jarvis2.Bus.subscribe("scenario:focus_mode")
    body = %{"context" => %{"focused_pane_id" => "w1:p1"}}
    Jarvis2.Web.Hooks.accept("action", "focus-mode", body)
    assert_receive {:herdr_write, %{"method" => "agent.view.set", "params" => params}}, 1_000
    assert params["source"] == "plugin:favetelinguis.jarvis2"
    assert params["filter"]["op"] == "any"

    assert [
             %{"field" => "workspace_id", "value" => %{"context" => "current_workspace_id"}},
             %{"field" => "status", "values" => ["blocked", "done"]}
           ] = params["filter"]["filters"]

    assert_receive {:jarvis2, "scenario:focus_mode", %{action: "focus-mode", outcome: :ok}}, 1_000
    Jarvis2.Web.Hooks.accept("action", "focus-mode-off", body)

    assert_receive {:herdr_write,
                    %{
                      "method" => "agent.view.clear",
                      "params" => %{"source" => "plugin:favetelinguis.jarvis2"}
                    }},
                   1_000

    assert_receive {:jarvis2, "scenario:focus_mode", %{action: "focus-mode-off", outcome: :ok}},
                   1_000
  end

  test "layout action resolves the hook context against a fresh mirror" do
    {socket, listener, path} = fake_socket()

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    view = %{
      stale: false,
      snapshot: %{
        "panes" => [
          %{
            "workspace_id" => "w1",
            "pane_id" => "w1:p1",
            "tab_id" => "w1:t1",
            "cwd" => File.cwd!()
          }
        ],
        "agents" => []
      }
    }

    {:ok, mirror} = start_supervised({StaticMirror, view})
    previous_mirror = Application.fetch_env(:jarvis2, :mirror)
    previous_socket = Application.fetch_env(:jarvis2, :herdr_socket)
    Application.put_env(:jarvis2, :mirror, mirror)
    Application.put_env(:jarvis2, :herdr_socket, socket)

    on_exit(fn ->
      restore_config(:mirror, previous_mirror)
      restore_config(:herdr_socket, previous_socket)
    end)

    Application.put_env(:jarvis2, :live, true)
    Application.put_env(:jarvis2, :live_scenarios, [:declarative_layout])
    start_supervised!({LayoutDev, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:declarative_layout")

    Jarvis2.Web.Hooks.accept("action", "layout-dev", %{
      "context" => %{"workspace_id" => "w2", "focused_pane_id" => "w1:p1"}
    })

    assert_receive {:jarvis2, "scenario:declarative_layout", %{outcome: :error}}, 1_000
    refute_receive {:herdr_write, _}, 30

    Jarvis2.Web.Hooks.accept("action", "layout-dev", %{
      "context" => %{"workspace_id" => "w1", "focused_pane_id" => "w1:p1"}
    })

    assert_receive {:herdr_write,
                    %{
                      "method" => "layout.apply",
                      "params" => %{"workspace_id" => "w1", "focus" => false}
                    }},
                   1_000

    assert_receive {:jarvis2, "scenario:declarative_layout", %{outcome: :ok}}, 1_000
  end

  test "explicitly enabled scenarios send only expected live requests" do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "scenario-#{System.unique_integer([:positive])}"
      )

    parent = self()

    handler = fn request ->
      send(parent, {:herdr_write, request})
      {:reply, %{result: %{type: "ok"}}}
    end

    {:ok, _fake, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Socket, [path: path, name: nil]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    Application.put_env(:jarvis2, :live, true)
    Application.put_env(:jarvis2, :live_scenarios, [:attention, :output_watcher])
    start_supervised!({Attention, [name: nil, socket: socket]})
    start_supervised!({OutputWatcher, [name: nil, socket: socket]})
    Jarvis2.Bus.subscribe("scenario:attention")
    Jarvis2.Bus.subscribe("scenario:output_watcher")

    Jarvis2.Bus.publish("herdr:pane.agent_status_changed", %{
      type: "pane.agent_status_changed",
      data: %{"pane_id" => "w1:p1", "agent_status" => "blocked"}
    })

    assert_receive {:herdr_write,
                    %{"method" => "notification.show", "params" => %{"sound" => "request"}}},
                   1_000

    assert_receive {:herdr_write, %{"method" => "client.window_title.set"}}, 1_000
    assert_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "blocked"}}, 1_000

    Jarvis2.Bus.publish("herdr:pane.focused", %{
      type: "pane.focused",
      data: %{"pane_id" => "w1:p2"}
    })

    refute_receive {:herdr_write, _}, 50

    Jarvis2.Bus.publish("herdr:pane.focused", %{
      type: "pane.focused",
      data: %{"pane_id" => "w1:p1"}
    })

    assert_receive {:herdr_write, %{"method" => "client.window_title.clear"}}, 1_000
    assert_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "cleared"}}, 1_000

    Jarvis2.Bus.publish("herdr:pane.output_matched", %{
      type: "pane.output_matched",
      data: %{"pane_id" => "w1:p1", "matched_line" => "FAIL test"}
    })

    assert_receive {:herdr_write,
                    %{"method" => "notification.show", "params" => %{"body" => "FAIL test"}}},
                   1_000

    assert_receive {:jarvis2, "scenario:output_watcher", %{pane: "w1:p1", dry_run: false}}, 1_000
  end

  defp fake_socket do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "scenario-#{System.unique_integer([:positive])}"
      )

    parent = self()

    handler = fn request ->
      send(parent, {:herdr_write, request})

      result =
        if request["method"] == "layout.apply",
          do: %{type: "layout_apply", layout: %{tab_id: "w1:t2"}},
          else: %{type: "ok"}

      {:reply, %{result: result}}
    end

    {:ok, _fake, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Socket, [path: path, name: nil]})
    {socket, listener, path}
  end

  defp restore_config(key, {:ok, value}), do: Application.put_env(:jarvis2, key, value)
  defp restore_config(key, :error), do: Application.delete_env(:jarvis2, key)
end
