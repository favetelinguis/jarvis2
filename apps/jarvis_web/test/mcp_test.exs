defmodule Jarvis2.MCPTest do
  use ExUnit.Case, async: false

  defmodule FakeMirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}

    def handle_call(:get, _from, %{stale_after_next: true} = view) do
      {:reply, Map.delete(view, :stale_after_next),
       view |> Map.delete(:stale_after_next) |> Map.put(:stale, true)}
    end

    def handle_call(:get, _from, view), do: {:reply, view, view}

    def handle_call(:arm_stale, _from, view),
      do: {:reply, :ok, Map.put(view, :stale_after_next, true)}

    def handle_cast(:stale, view), do: {:noreply, %{view | stale: true}}
  end

  setup do
    snapshot = %{
      "workspaces" => [%{"workspace_id" => "w1", "label" => "work"}],
      "tabs" => [%{"tab_id" => "w1:t1", "workspace_id" => "w1"}],
      "panes" => [
        %{"pane_id" => "w1:p1", "tab_id" => "w1:t1", "workspace_id" => "w1", "cwd" => File.cwd!()}
      ],
      "agents" => [
        %{
          "pane_id" => "w1:p1",
          "workspace_id" => "w1",
          "agent" => "pi",
          "name" => "agent-one",
          "agent_status" => "idle"
        }
      ],
      "layouts" => [%{"tab_id" => "w1:t1", "panes" => []}]
    }

    view = %{
      snapshot: snapshot,
      worktrees: %{"repo" => [%{"path" => "/repo/other"}]},
      worktree_errors: %{},
      layout_diff: %{
        sequence: 3,
        status: "changed",
        changes: [%{kind: "focus"}],
        truncated: false
      },
      stale: false
    }

    {:ok, mirror} = start_supervised({FakeMirror, view})
    previous = Application.get_env(:jarvis2, :mirror)
    Application.put_env(:jarvis2, :mirror, mirror)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:jarvis2, :mirror, previous),
        else: Application.delete_env(:jarvis2, :mirror)
    end)

    start_supervised!({Finch, name: Jarvis2.MCPTestFinch})

    {:ok, server} =
      start_supervised({Bandit, plug: Jarvis2.Web.Router, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{port: port, token: Jarvis2.Token.get(), mirror: mirror}
  end

  test "streamable HTTP exposes tools, caller identity, blackboard and resources", ctx do
    {session, protocol} = initialize(ctx)

    headers = [
      {"mcp-session-id", session},
      {"mcp-protocol-version", protocol},
      {"x-herdr-pane", "w1:p1"},
      {"x-herdr-workspace", "w1"}
    ]

    assert {202, _, _} = rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})

    {200, _, %{"result" => %{"tools" => tools}}} =
      rpc(ctx, headers, %{jsonrpc: "2.0", id: 2, method: "tools/list"})

    names = Enum.map(tools, & &1["name"])
    refute "ask_human" in names

    assert Enum.all?(
             ~w(whoami log blackboard_put blackboard_get blackboard_list list_agents get_layout list_worktrees report_status notify_human read_agent prompt_agent wait_for_event run_mix elixir_eval apply_layout),
             &(&1 in names)
           )

    put_schema = Enum.find(tools, &(&1["name"] == "blackboard_put"))["inputSchema"]
    assert "value" in put_schema["required"]
    identity = call_tool(ctx, headers, "whoami", %{})
    assert identity["pane"] == "w1:p1"
    assert identity["workspace"] == "w1"
    assert identity["agent_kind"] == "pi"
    assert identity["mode"] == "dry"
    key = "mcp-#{System.unique_integer([:positive])}"

    assert call_tool(ctx, headers, "blackboard_put", %{key: key, value: %{answer: 42}})["ok"] ==
             true

    assert call_tool(ctx, headers, "blackboard_get", %{key: key})["value"] == %{"answer" => 42}
    assert call_tool(ctx, headers, "blackboard_list", %{})[key] == %{"answer" => 42}
    null_key = key <> "-null"
    assert call_tool(ctx, headers, "blackboard_put", %{key: null_key, value: nil})["ok"] == true
    null_value = call_tool(ctx, headers, "blackboard_get", %{key: null_key})
    assert null_value["found"] == true and null_value["value"] == nil
    layout = call_tool(ctx, headers, "get_layout", %{workspace: "w1", format: "json"})
    assert [%{"tab_id" => "w1:t1"}] = layout["layouts"]
    assert call_tool(ctx, headers, "get_layout", %{format: "tree"})["tree"] =~ "workspace w1"
    assert length(call_tool(ctx, headers, "list_agents", %{})["agents"]) == 1

    assert call_tool(ctx, headers, "list_worktrees", %{})["worktrees"]["repo"] == [
             %{"path" => "/repo/other"}
           ]

    assert call_tool(ctx, headers, "notify_human", %{title: "hello"})["dry_run"] == true

    assert call_tool(ctx, headers, "report_status", %{state: "working", summary: "testing"})[
             "dry_run"
           ] == true

    {200, _, %{"result" => %{"resources" => resources}}} =
      rpc(ctx, headers, %{jsonrpc: "2.0", id: 3, method: "resources/list"})

    assert Enum.any?(resources, &(&1["uri"] == "jarvis2://blackboard"))

    {200, _, %{"result" => %{"contents" => [%{"text" => content}]}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 4,
        method: "resources/read",
        params: %{uri: "jarvis2://blackboard"}
      })

    assert Jason.decode!(content)[key] == %{"answer" => 42}

    {200, _, %{"result" => %{"contents" => [%{"text" => layout_content}]}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 6,
        method: "resources/read",
        params: %{uri: "jarvis2://layout"}
      })

    layout_resource = Jason.decode!(layout_content)
    assert layout_resource["tree"] =~ "workspace w1"
    assert [%{"pane_id" => "w1:p1"}] = layout_resource["layout"]["agents"]

    assert %{"sequence" => 3, "status" => "changed", "changes" => [%{"kind" => "focus"}]} =
             layout_resource["layout_diff"]

    assert Enum.any?(
             Jarvis2.State.recent_journal(),
             &match?(%{tool: "whoami", caller: %{pane: "w1:p1"}}, &1)
           )
  end

  test "invalid tool calls are journalled and browser origins are rejected", ctx do
    assert {403, _, %{"error" => "browser origins are not supported"}} =
             rpc(ctx, [{"origin", "https://attacker.example"}], %{
               jsonrpc: "2.0",
               id: 1,
               method: "initialize"
             })

    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})

    {200, _, %{"error" => _}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: %{name: "report_status", arguments: %{state: "bad", summary: "x"}}
      })

    assert Enum.any?(
             Jarvis2.State.recent_journal(),
             &match?(%{tool: "report_status", outcome: "error"}, &1)
           )

    {200, _, %{"error" => _}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 5,
        method: "tools/call",
        params: %{name: "blackboard_put", arguments: %{key: "missing"}}
      })

    assert Enum.any?(
             Jarvis2.State.recent_journal(),
             &match?(%{tool: "blackboard_put", outcome: "error"}, &1)
           )

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 4,
        method: "tools/call",
        params: %{name: "report_status", arguments: %{state: "working", summary: "x"}}
      })
  end

  test "log redacts common credentials", ctx do
    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert call_tool(ctx, headers, "log", %{
                 level: "info",
                 message: "token=private-value Bearer hidden-token"
               })["ok"]
      end)

    assert log =~ "[redacted]"
    refute log =~ "private-value"
    refute log =~ "hidden-token"
  end

  test "a tool call and its journal use the same resolved identity", ctx do
    {session, protocol} = initialize(ctx)

    headers = [
      {"mcp-session-id", session},
      {"mcp-protocol-version", protocol},
      {"x-herdr-pane", "w1:p1"},
      {"x-herdr-workspace", "w1"}
    ]

    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    :ok = GenServer.call(ctx.mirror, :arm_stale)
    assert call_tool(ctx, headers, "whoami", %{})["pane"] == "w1:p1"
    assert List.last(Jarvis2.State.recent_journal()).caller.pane == "w1:p1"
  end

  test "missing, mismatched and stale identities never resolve to a pane", ctx do
    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    assert call_tool(ctx, headers, "whoami", %{})["pane"] == "unknown"

    assert call_tool(
             ctx,
             headers ++ [{"x-herdr-pane", "w1:p1"}, {"x-herdr-workspace", "w2"}],
             "whoami",
             %{}
           )["pane"] == "unknown"

    assert call_tool(ctx, headers ++ [{"x-herdr-pane", "w1:p1"}], "whoami", %{})["pane"] ==
             "unknown"

    assert call_tool(ctx, headers ++ [{"x-herdr-pane", "w1:p9"}], "whoami", %{})["pane"] ==
             "unknown"

    GenServer.cast(ctx.mirror, :stale)
    assert GenServer.call(ctx.mirror, :get).stale

    assert call_tool(
             ctx,
             headers ++ [{"x-herdr-pane", "w1:p1"}, {"x-herdr-workspace", "w1"}],
             "whoami",
             %{}
           )["pane"] ==
             "unknown"

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 9,
        method: "tools/call",
        params: %{name: "list_agents", arguments: %{}}
      })
  end

  test "report_status updates sidebar and schedules pane hygiene for the resolved caller", ctx do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "mcp-status-#{System.unique_integer([:positive])}"
      )

    parent = self()

    handler = fn request ->
      send(parent, {:herdr_status, request})
      {:reply, %{result: %{type: "ok"}}}
    end

    {:ok, _fake, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Jarvis2.Herdr.Socket, [path: path, name: nil]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    replace_config(:herdr_socket, socket)
    replace_config(:live, true)
    replace_config(:live_scenarios, [:sidebar_tokens, :pane_hygiene])

    start_supervised!(
      {Jarvis2.Scenarios.Presentation,
       [name: nil, mirror: ctx.mirror, socket: socket, debounce_ms: 20]}
    )

    {session, protocol} = initialize(ctx)

    headers = [
      {"mcp-session-id", session},
      {"mcp-protocol-version", protocol},
      {"x-herdr-pane", "w1:p1"},
      {"x-herdr-workspace", "w1"}
    ]

    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert call_tool(ctx, headers, "report_status", %{
                 state: "working",
                 summary: "building\nfeature"
               })["type"] == "ok"

        assert_receive {:herdr_status,
                        %{
                          "method" => "pane.report_metadata",
                          "params" => %{
                            "pane_id" => "w1:p1",
                            "tokens" => %{"jarvis" => "working: building feature"}
                          }
                        }},
                       1_000

        assert_receive {:herdr_status,
                        %{
                          "method" => "pane.rename",
                          "params" => %{"pane_id" => "w1:p1", "label" => "pi: building feature"}
                        }},
                       1_000

        assert_receive {:herdr_status,
                        %{
                          "method" => "workspace.report_metadata",
                          "params" => %{
                            "workspace_id" => "w1",
                            "tokens" => %{"last_tool" => "report_status"}
                          }
                        }},
                       1_000
      end)

    refute log =~ "building"
    GenServer.call(ctx.mirror, :arm_stale)

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 32,
        method: "tools/call",
        params: %{name: "report_status", arguments: %{state: "done", summary: "stale"}}
      })

    refute_receive {:herdr_status, _}, 150
  end

  test "apply_layout returns a dry-run plan for the calling workspace", ctx do
    {session, protocol} = initialize(ctx)

    headers = [
      {"mcp-session-id", session},
      {"mcp-protocol-version", protocol},
      {"x-herdr-pane", "w1:p1"},
      {"x-herdr-workspace", "w1"}
    ]

    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    result = call_tool(ctx, headers, "apply_layout", %{name: "dev"})
    assert result["dry_run"] == true and result["workspace_id"] == "w1"
    assert result["root"]["type"] == "split"

    {200, _, %{"error" => _}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 29,
        method: "tools/call",
        params: %{name: "apply_layout", arguments: %{name: "replace-any-tab"}}
      })
  end

  test "apply_layout creates a new scoped tab and rejects unknown or stale callers", ctx do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "mcp-layout-#{System.unique_integer([:positive])}"
      )

    parent = self()

    {:ok, layout_state} = start_supervised({Agent, fn -> nil end})

    handler = fn request ->
      send(parent, {:herdr_layout, request})

      result =
        case request["method"] do
          "layout.apply" ->
            root =
              request["params"]["root"]
              |> put_in(["first", "pane_id"], "w1:p2")
              |> put_in(["second", "first", "pane_id"], "w1:p3")
              |> put_in(["second", "second", "pane_id"], "w1:p4")

            layout = %{
              "workspace_id" => "w1",
              "tab_id" => "w1:t2",
              "zoomed" => false,
              "focused_pane_id" => "w1:p2",
              "root" => root
            }

            Agent.update(layout_state, fn _ -> layout end)
            %{type: "layout_apply", layout: layout}

          "layout.export" ->
            %{type: "layout_export", layout: Agent.get(layout_state, & &1)}

          "layout.set_split_ratio" ->
            layout =
              Agent.get_and_update(layout_state, fn old ->
                updated = put_in(old, ["root", "ratio"], request["params"]["ratio"])
                {updated, updated}
              end)

            %{type: "layout_split_ratio_set", layout: layout}
        end

      {:reply, %{result: result}}
    end

    {:ok, _fake, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Jarvis2.Herdr.Socket, [path: path, name: nil]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    replace_config(:herdr_socket, socket)
    replace_config(:live, true)
    replace_config(:live_scenarios, [:declarative_layout])
    {session, protocol} = initialize(ctx)
    base = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    headers = base ++ [{"x-herdr-pane", "w1:p1"}, {"x-herdr-workspace", "w1"}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    result = call_tool(ctx, headers, "apply_layout", %{name: "dev"})
    assert result["type"] == "layout_apply"
    assert result["demo"]["status"] == "complete"
    assert result["layout"]["root"]["ratio"] == 0.65
    assert_receive {:herdr_layout, %{"method" => "layout.apply", "params" => params}}
    assert params["workspace_id"] == "w1" and params["focus"] == false
    refute Map.has_key?(params, "tab_id")
    assert params["root"]["first"]["label"] == "editor"
    assert params["root"]["second"]["first"]["label"] == "tests"
    assert params["root"]["second"]["second"]["label"] == "agent"
    assert params["root"]["first"]["cwd"] == File.cwd!()
    refute Jason.encode!(params) =~ "command"

    assert_receive {:herdr_layout,
                    %{"method" => "layout.export", "params" => %{"tab_id" => "w1:t2"}}}

    assert_receive {:herdr_layout,
                    %{
                      "method" => "layout.set_split_ratio",
                      "params" => %{"tab_id" => "w1:t2", "path" => [], "ratio" => 0.65}
                    }}

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, base, %{
        jsonrpc: "2.0",
        id: 30,
        method: "tools/call",
        params: %{name: "apply_layout", arguments: %{name: "dev"}}
      })

    GenServer.call(ctx.mirror, :arm_stale)

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 31,
        method: "tools/call",
        params: %{name: "apply_layout", arguments: %{name: "dev"}}
      })

    refute_receive {:herdr_layout, _}, 50
  end

  test "reads an agent through the Herdr client and limits requested lines", ctx do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "mcp-read-#{System.unique_integer([:positive])}"
      )

    parent = self()

    handler = fn request ->
      send(parent, {:herdr_read, request})
      {:reply, %{result: %{type: "agent_read", read: %{text: "agent output"}}}}
    end

    {:ok, _fake, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Jarvis2.Herdr.Socket, [path: path, name: nil]})
    replace_config(:herdr_socket, socket)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})

    assert call_tool(ctx, headers, "read_agent", %{agent: "agent-one", lines: 20})["read"]["text"] ==
             "agent output"

    assert_receive {:herdr_read,
                    %{
                      "method" => "agent.read",
                      "params" => %{
                        "target" => "agent-one",
                        "lines" => 20,
                        "source" => "recent_unwrapped"
                      }
                    }}

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 11,
        method: "tools/call",
        params: %{name: "read_agent", arguments: %{agent: "agent-one", lines: 500}}
      })
  end

  test "wait_for_event filters future bus events and does not reset its deadline", ctx do
    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    topic = "herdr:pane.jarvis_test"

    task =
      Task.async(fn ->
        call_tool(ctx, headers, "wait_for_event", %{
          match: %{type: "pane.jarvis_test", filters: %{pane_id: "w1:p1"}},
          timeout_s: 2
        })
      end)

    eventually(fn -> Registry.lookup(Jarvis2.Registry, topic) != [] end)
    Jarvis2.Bus.publish(topic, %{type: "pane.jarvis_test", data: %{"pane_id" => "w1:p2"}})
    assert Task.yield(task, 50) == nil

    Jarvis2.Bus.publish(topic, %{
      type: "pane.jarvis_test",
      data: %{"pane_id" => "w1:p1", "agent_status" => "done"}
    })

    assert Task.await(task, 3_000)["event"]["data"]["agent_status"] == "done"
    assert Registry.lookup(Jarvis2.Registry, topic) == []

    assert call_tool(ctx, headers, "wait_for_event", %{
             match: %{type: "pane.jarvis_timeout"},
             timeout_s: 1
           })["timeout"] == true
  end

  test "event waits enforce a fixed deadline even under a stream of mismatches", ctx do
    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    topic = "herdr:pane.jarvis_flood"

    waiter =
      Task.async(fn ->
        call_tool(ctx, headers, "wait_for_event", %{
          match: %{type: "pane.jarvis_flood", filters: %{marker: nil}},
          timeout_s: 1
        })
      end)

    eventually(fn -> Registry.lookup(Jarvis2.Registry, topic) != [] end)

    producer =
      Task.async(fn ->
        for _ <- 1..150 do
          Jarvis2.Bus.publish(topic, %{type: "pane.jarvis_flood", data: %{}})
          Process.sleep(20)
        end
      end)

    assert Task.await(waiter, 2_500)["timeout"] == true
    Task.shutdown(producer, :brutal_kill)

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 16,
        method: "tools/call",
        params: %{
          name: "wait_for_event",
          arguments: %{match: %{type: "pane.jarvis_flood", filters: false}, timeout_s: 1}
        }
      })
  end

  test "run_mix only runs allow-listed argv in the configured project and bounds output", ctx do
    root = Path.join(Application.fetch_env!(:jarvis2, :state_dir), "mix-project")
    File.mkdir_p!(root)
    executable = Path.join(root, "fake-mix")
    capture = Path.join(root, "args")

    File.write!(
      executable,
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$JARVIS2_TEST_MIX_ARGS\"\nprintf '%020000d' 0\n"
    )

    File.chmod!(executable, 0o700)
    previous_capture = System.get_env("JARVIS2_TEST_MIX_ARGS")
    System.put_env("JARVIS2_TEST_MIX_ARGS", capture)

    on_exit(fn ->
      if previous_capture,
        do: System.put_env("JARVIS2_TEST_MIX_ARGS", previous_capture),
        else: System.delete_env("JARVIS2_TEST_MIX_ARGS")
    end)

    replace_config(:mix_project_dir, root)
    replace_config(:mix_executable, executable)
    replace_config(:mix_timeout_ms, 2_000)
    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    result = call_tool(ctx, headers, "run_mix", %{task: "format --check-formatted"})
    assert result["exit_status"] == 0 and result["truncated"] == true
    assert byte_size(result["output"]) <= 16_384
    assert File.read!(capture) == "format\n--check-formatted\n"
    File.rm!(capture)

    {200, _, %{"error" => _}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 12,
        method: "tools/call",
        params: %{name: "run_mix", arguments: %{task: "test; touch bad"}}
      })

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 13,
        method: "tools/call",
        params: %{name: "run_mix", arguments: %{task: "test", project: "/tmp"}}
      })

    refute File.exists?(capture)
  end

  test "run_mix runs a real Mix compile in the configured project", ctx do
    root = Path.join(Application.fetch_env!(:jarvis2, :state_dir), "real-mix-project")
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Example.MixProject do\n  use Mix.Project\n  def project, do: [app: :example, version: \"0.1.0\"]\nend\n"
    )

    replace_config(:mix_project_dir, root)
    replace_config(:mix_executable, System.find_executable("mix"))
    replace_config(:mix_timeout_ms, 20_000)
    old_flags = System.get_env("ERL_FLAGS")
    System.put_env("ERL_FLAGS", "+S 2:2")

    on_exit(fn ->
      if old_flags,
        do: System.put_env("ERL_FLAGS", old_flags),
        else: System.delete_env("ERL_FLAGS")
    end)

    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    result = call_tool(ctx, headers, "run_mix", %{task: "compile"})
    assert result["exit_status"] == 0 and not result["timed_out"]
    assert File.dir?(Path.join(root, "_build"))
  end

  test "run_mix rejects concurrent executions", ctx do
    root = Path.join(Application.fetch_env!(:jarvis2, :state_dir), "concurrent-project")
    File.mkdir_p!(root)
    executable = Path.join(root, "fake-mix")
    File.write!(executable, "#!/bin/sh\nexec /usr/bin/sleep 0.4\n")
    File.chmod!(executable, 0o700)
    replace_config(:mix_project_dir, root)
    replace_config(:mix_executable, executable)
    replace_config(:mix_timeout_ms, 2_000)
    {session1, protocol1} = initialize(ctx)
    {session2, protocol2} = initialize(ctx)
    headers1 = [{"mcp-session-id", session1}, {"mcp-protocol-version", protocol1}]
    headers2 = [{"mcp-session-id", session2}, {"mcp-protocol-version", protocol2}]
    rpc(ctx, headers1, %{jsonrpc: "2.0", method: "notifications/initialized"})
    rpc(ctx, headers2, %{jsonrpc: "2.0", method: "notifications/initialized"})
    first = Task.async(fn -> call_tool(ctx, headers1, "run_mix", %{task: "compile"}) end)
    eventually(fn -> Registry.lookup(Jarvis2.MixRegistry, :run) != [] end)

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers2, %{
        jsonrpc: "2.0",
        id: 18,
        method: "tools/call",
        params: %{name: "run_mix", arguments: %{task: "compile"}}
      })

    assert Task.await(first, 3_000)["exit_status"] == 0
  end

  test "run_mix safely bounds non-UTF-8 output", ctx do
    root = Path.join(Application.fetch_env!(:jarvis2, :state_dir), "binary-project")
    File.mkdir_p!(root)
    executable = Path.join(root, "fake-mix")

    File.write!(
      executable,
      "#!/usr/bin/python3\nimport sys\nsys.stdout.buffer.write(b'\\xff' * 10000)\n"
    )

    File.chmod!(executable, 0o700)
    replace_config(:mix_project_dir, root)
    replace_config(:mix_executable, executable)
    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    result = call_tool(ctx, headers, "run_mix", %{task: "compile"})
    assert result["exit_status"] == 0 and result["truncated"]
    assert String.valid?(result["output"]) and byte_size(result["output"]) <= 16_384
    assert result["output"] =~ "�"
  end

  test "run_mix times out and eval is disabled unless explicitly enabled", ctx do
    root = Path.join(Application.fetch_env!(:jarvis2, :state_dir), "timeout-project")
    File.mkdir_p!(root)
    executable = Path.join(root, "fake-mix")
    File.write!(executable, "#!/bin/sh\nexec /usr/bin/sleep 5\n")
    File.chmod!(executable, 0o700)
    replace_config(:mix_project_dir, root)
    replace_config(:mix_executable, executable)
    replace_config(:mix_timeout_ms, 100)
    replace_config(:allow_eval, false)
    {session, protocol} = initialize(ctx)
    headers = [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}]
    rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    assert call_tool(ctx, headers, "run_mix", %{task: "compile"})["timed_out"] == true

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 14,
        method: "tools/call",
        params: %{name: "elixir_eval", arguments: %{code: "1 + 1"}}
      })

    Application.put_env(:jarvis2, :allow_eval, true)
    assert call_tool(ctx, headers, "elixir_eval", %{code: "1 + 1"})["result"] == "2"
    replace_config(:eval_timeout_ms, 50)

    {200, _, %{"result" => %{"isError" => true}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 15,
        method: "tools/call",
        params: %{name: "elixir_eval", arguments: %{code: "Process.sleep(5000)"}}
      })
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

  defp initialize(ctx) do
    {200, headers, %{"result" => %{"protocolVersion" => protocol}}} =
      rpc(ctx, [], %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "test", version: "1"}
        }
      })

    {headers
     |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "mcp-session-id", do: v end),
     protocol}
  end

  defp call_tool(ctx, headers, name, args) do
    {200, _, %{"result" => %{"content" => [%{"text" => text}]}}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 10,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })

    Jason.decode!(text)
  end

  defp rpc(ctx, headers, request) do
    headers = [
      {"authorization", "Bearer " <> ctx.token},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"} | headers
    ]

    request =
      Finch.build(:post, "http://127.0.0.1:#{ctx.port}/mcp", headers, Jason.encode!(request))

    {:ok, response} = Finch.request(request, Jarvis2.MCPTestFinch, receive_timeout: 30_000)

    body =
      cond do
        response.body == "" ->
          nil

        String.starts_with?(response.body, "event:") ->
          response.body
          |> String.split("\n")
          |> Enum.find(&String.starts_with?(&1, "data:"))
          |> String.replace_prefix("data:", "")
          |> String.trim()
          |> Jason.decode!()

        true ->
          Jason.decode!(response.body)
      end

    {response.status, response.headers, body}
  end
end
