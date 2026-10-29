defmodule Jarvis2.ExecutionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
    def handle_call({:put, view}, _from, _), do: {:reply, :ok, view}
  end

  setup do
    pane = %{
      "pane_id" => "w1:p1",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "terminal_id" => "term1",
      "cwd" => File.cwd!()
    }

    agent = %{
      "pane_id" => "w1:p1",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "terminal_id" => "term1",
      "agent" => "pi",
      "name" => "caller",
      "agent_status" => "idle"
    }

    snapshot = %{
      "workspaces" => [%{"workspace_id" => "w1"}],
      "tabs" => [%{"tab_id" => "w1:t1", "workspace_id" => "w1"}],
      "panes" => [pane],
      "agents" => [agent],
      "layouts" => []
    }

    view = %{snapshot: snapshot, stale: false, worktrees: %{}, worktree_errors: %{}}
    mirror = start_supervised!({Mirror, view})
    guard = start_supervised!({Jarvis2.Herdr.ExecutionGuard, [name: nil]})
    prompt_guard = start_supervised!({Jarvis2.Herdr.PromptGuard, [name: nil]})

    fixture =
      start_supervised!(
        {Agent,
         fn ->
           %{snapshot: snapshot, fail: %{}, counter: 1, process: :shell, output: "test output"}
         end}
      )

    parent = self()

    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "execution-#{System.unique_integer([:positive])}"
      )

    handler = fn %{"method" => method, "params" => params} ->
      send(parent, {:request, method, params})

      case Agent.get(fixture, &Map.get(&1.fail, method)) do
        :disconnect -> :close
        {:error, code} -> {:reply, %{error: %{code: code, message: "private vendor error"}}}
        {:delay, ms} -> {:later, ms, %{result: %{type: "ok"}}}
        nil -> respond(method, params, fixture, mirror)
      end
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    socket = start_supervised!({Jarvis2.Herdr.Socket, [name: nil, path: path]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    config(:mirror, mirror)
    config(:execution_guard, guard)
    config(:prompt_guard, prompt_guard)
    config(:herdr_socket, socket)
    config(:live, false)
    config(:live_scenarios, [])
    start_supervised!({Finch, name: Jarvis2.ExecutionTestFinch})
    server = start_supervised!({Bandit, plug: Jarvis2.Web.Router, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{port: port, token: Jarvis2.Token.get(), fixture: fixture, mirror: mirror, view: view}
  end

  test "discovers guarded tools and simulates them without sending mutations", ctx do
    h = session(ctx)

    {200, _, %{"result" => %{"tools" => tools}}} =
      rpc(ctx, h, %{jsonrpc: "2.0", id: 2, method: "tools/list"})

    assert Enum.all?(~w(spawn_agent run_command), fn n -> Enum.any?(tools, &(&1["name"] == n)) end)

    assert {:ok, %{"dry_run" => true}} =
             call(ctx, h, "spawn_agent", %{name: "reviewer", kind: "pi"})

    assert {:ok, %{"dry_run" => true}} = call(ctx, h, "run_command", %{command: "mix test"})
    refute_receive {:request, _, _}, 100
  end

  test "requires recognized fresh caller, safe parameters and caller cwd", ctx do
    h = session(ctx)
    unknown = session(ctx, nil, nil)
    assert {:error, _} = call(ctx, unknown, "run_command", %{command: "mix test"})
    assert {:error, _} = call(ctx, h, "run_command", %{command: "echo ok\nrm -rf /"})
    assert {:error, _} = call(ctx, h, "spawn_agent", %{name: "INVALID", kind: "pi"})
    assert {:error, _} = call(ctx, h, "spawn_agent", %{name: "reviewer", kind: "unknown"})
    assert {:error, _} = call(ctx, h, "spawn_agent", %{name: "reviewer", kind: "pi", cwd: "/"})
    GenServer.call(ctx.mirror, {:put, %{ctx.view | stale: true}})
    assert {:error, _} = call(ctx, h, "run_command", %{command: "mix test"})
    refute_receive {:request, _, _}, 100
  end

  test "limits attempts per caller across tools without sending writes in dry mode", ctx do
    h = session(ctx)

    for _ <- 1..4,
        do:
          assert({:ok, %{"dry_run" => true}} = call(ctx, h, "run_command", %{command: "echo hi"}))

    assert {:error, message} = call(ctx, h, "spawn_agent", %{name: "reviewer", kind: "pi"})
    assert message =~ "rate"
    refute_receive {:request, _, _}, 100
  end

  test "live command creates a sibling, checks shell occupancy and reads bounded output", ctx do
    config(:live, true)
    config(:live_scenarios, [:run_command])
    h = session(ctx)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, result} =
                 call(ctx, h, "run_command", %{
                   command: "echo private-command",
                   wait_for: "finished",
                   timeout_s: 2
                 })

        assert result["pane_id"] == "w1:p2"
        assert result["output"] == "test output"
        assert_receive {:request, "pane.split", %{"target_pane_id" => "w1:p1", "focus" => false}}
        assert_receive {:request, "pane.process_info", %{"pane_id" => "w1:p2"}}

        assert_receive {:request, "pane.send_input",
                        %{
                          "pane_id" => "w1:p2",
                          "text" => "echo private-command",
                          "keys" => ["enter"]
                        }}

        assert_receive {:request, "pane.wait_for_output",
                        %{
                          "pane_id" => "w1:p2",
                          "match" => %{"type" => "substring", "value" => "finished"}
                        }}

        assert_receive {:request, "pane.read", %{"pane_id" => "w1:p2"}}
      end)

    refute log =~ "private-command"
    refute inspect(Jarvis2.State.recent_journal()) =~ "private-command"
  end

  test "run_command emits request-scoped MCP progress", ctx do
    config(:live, true)
    config(:live_scenarios, [:run_command])
    h = session(ctx)

    parent = self()
    url = "http://127.0.0.1:#{ctx.port}/mcp"

    stream_headers = [
      {"authorization", "Bearer " <> ctx.token},
      {"accept", "text/event-stream"} | h
    ]

    stream =
      Task.async(fn ->
        request = Finch.build(:get, url, stream_headers)

        Finch.stream(
          request,
          Jarvis2.ExecutionTestFinch,
          nil,
          fn event, acc ->
            case event do
              {:headers, _} -> send(parent, :stream_ready)
              {:data, data} -> send(parent, {:stream_data, data})
              _ -> :ok
            end

            acc
          end,
          receive_timeout: 30_000
        )
      end)

    on_exit(fn -> if Process.alive?(stream.pid), do: Process.exit(stream.pid, :kill) end)
    assert_receive :stream_ready, 2_000

    body = %{
      jsonrpc: "2.0",
      id: 19,
      method: "tools/call",
      params: %{
        name: "run_command",
        arguments: %{command: "echo hi"},
        _meta: %{progressToken: "test-progress"}
      }
    }

    assert {200, _, %{"result" => _}} = rpc(ctx, h, body)
    events = receive_progress("", [])
    assert Enum.map(events, & &1["params"]["progress"]) == [0, 1, 2]
    assert Enum.all?(events, &(&1["params"]["progressToken"] == "test-progress"))

    session_id =
      h |> Enum.find_value(fn {key, value} -> if key == "mcp-session-id", do: value end)

    transport = Anubis.Server.Registry.transport_name(Jarvis2.MCP.Server, :streamable_http)
    handler = Anubis.Server.Transport.StreamableHTTP.get_sse_handler(transport, session_id)
    send(handler, :close_sse)
    assert {:ok, _} = Task.await(stream, 2_000)
  end

  test "live picker answers one authenticated request without logging its contents", ctx do
    config(:live, true)
    config(:live_scenarios, [:human_picker])
    config(:port, ctx.port)
    h = session(ctx)

    log =
      capture_log(fn ->
        task =
          Task.async(fn ->
            call(ctx, h, "ask_human", %{
              question: "private question?",
              choices: ["private choice", "second"],
              timeout_s: 5
            })
          end)

        assert_receive {:request, "plugin.pane.open", params}, 2_000
        assert params["entrypoint"] == "picker"
        refute Map.has_key?(params, "target_pane_id")
        id = params["env"]["JARVIS2_PICKER_ID"]
        assert {401, _} = picker_request(ctx, id, :get, nil, false)

        assert {200,
                %{"question" => "private question?", "choices" => ["private choice", "second"]}} =
                 picker_request(ctx, id, :get)

        assert {400, _} = picker_request(ctx, id, :post, %{index: 2})
        assert {200, _} = picker_request(ctx, id, :post, %{index: 0})

        assert {:ok, %{"answer" => "private choice", "dry_run" => false}} =
                 Task.await(task, 2_000)

        assert {404, _} = picker_request(ctx, id, :get)
        assert {400, _} = picker_request(ctx, id, :post, %{index: 0})
      end)

    refute log =~ "private question"
    refute log =~ "private choice"
    refute inspect(Jarvis2.State.recent_journal()) =~ "private question"
  end

  test "send-to-agent action asks for a target and message before a guarded prompt", ctx do
    config(:live, true)
    config(:live_scenarios, [:human_picker, :agent_prompt])
    config(:port, ctx.port)

    target_pane = %{
      "pane_id" => "w1:p2",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "terminal_id" => "term2",
      "cwd" => File.cwd!()
    }

    target =
      Map.merge(target_pane, %{"agent" => "pi", "name" => "reviewer", "agent_status" => "idle"})

    snapshot =
      ctx.view.snapshot
      |> Map.update!("panes", &(&1 ++ [target_pane]))
      |> Map.update!("agents", &(&1 ++ [target]))

    GenServer.call(ctx.mirror, {:put, %{ctx.view | snapshot: snapshot}})
    start_supervised!({Jarvis2.Scenarios.SendToAgent, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:send_to_agent")

    headers = [{"authorization", "Bearer " <> ctx.token}, {"content-type", "application/json"}]
    body = Jason.encode!(%{context: %{workspace_id: "w1", focused_pane_id: "w1:p1"}})

    request =
      Finch.build(:post, "http://127.0.0.1:#{ctx.port}/hook/action/send-to-agent", headers, body)

    assert {:ok, %{status: 202}} = Finch.request(request, Jarvis2.ExecutionTestFinch)
    assert_receive {:request, "plugin.pane.open", first}, 2_000
    id = first["env"]["JARVIS2_PICKER_ID"]
    assert {200, %{"choices" => ["w1:p2"]}} = picker_request(ctx, id, :get)
    assert {200, _} = picker_request(ctx, id, :post, %{index: 0})
    assert_receive {:request, "plugin.pane.open", second}, 2_000

    assert {200, _} =
             picker_request(ctx, second["env"]["JARVIS2_PICKER_ID"], :post, %{
               text: "review privately"
             })

    assert_receive {:request, "agent.prompt",
                    %{"target" => "w1:p2", "text" => "review privately"}},
                   2_000

    assert_receive {:jarvis2, "scenario:send_to_agent", %{outcome: :ok}}, 2_000
    refute inspect(Jarvis2.State.recent_journal()) =~ "review privately"
  end

  test "send-to-agent does not open a picker unless both scenarios are live", _ctx do
    config(:live, true)
    config(:live_scenarios, [:human_picker])
    scenario = start_supervised!({Jarvis2.Scenarios.SendToAgent, [name: nil]})

    Jarvis2.Web.Hooks.accept("action", "send-to-agent", %{
      "context" => %{"workspace_id" => "w1", "focused_pane_id" => "w1:p1"}
    })

    :sys.get_state(scenario)
    refute_receive {:request, "plugin.pane.open", _}, 150
    refute_receive {:request, "agent.prompt", _}, 150
  end

  test "docs link action validates the URL and opens a gated popup", ctx do
    config(:live, true)
    config(:live_scenarios, [:docs_link])
    start_supervised!({Jarvis2.Scenarios.DocsLink, [name: nil]})
    Jarvis2.Bus.subscribe("scenario:docs_link")
    headers = [{"authorization", "Bearer " <> ctx.token}, {"content-type", "application/json"}]

    post = fn url ->
      body =
        Jason.encode!(%{
          context: %{workspace_id: "w1", focused_pane_id: "w1:p1"},
          clicked_url: url
        })

      request =
        Finch.build(:post, "http://127.0.0.1:#{ctx.port}/hook/action/docs-link", headers, body)

      assert {:ok, %{status: 202}} = Finch.request(request, Jarvis2.ExecutionTestFinch)
    end

    post.("https://hexdocs.pm@evil.example/secret")
    post.("https://hexdocs.pm:invalid/elixir/Enum.html")
    refute_receive {:request, "plugin.pane.open", _}, 100

    log =
      capture_log(fn ->
        post.("https://hexdocs.pm/elixir/Enum.html?secret=private")
        assert_receive {:request, "plugin.pane.open", params}, 2_000
        assert params["entrypoint"] == "docs"

        assert params["env"]["JARVIS2_DOCS_URL"] ==
                 "https://hexdocs.pm/elixir/Enum.html?secret=private"

        assert_receive {:jarvis2, "scenario:docs_link", %{outcome: :ok}}, 2_000
      end)

    refute log =~ "private"
  end

  test "live picker timeout makes its popup request unavailable", ctx do
    config(:live, true)
    config(:live_scenarios, [:human_picker])
    config(:port, ctx.port)
    h = session(ctx)

    task =
      Task.async(fn ->
        call(ctx, h, "ask_human", %{question: "Choose", choices: ["one"], timeout_s: 1})
      end)

    assert_receive {:request, "plugin.pane.open", params}, 2_000
    id = params["env"]["JARVIS2_PICKER_ID"]
    assert {:error, message} = Task.await(task, 3_000)
    assert message =~ "timed out"
    assert {404, _} = picker_request(ctx, id, :get)
  end

  test "separate live gates do not enable execution", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_spawn])
    h = session(ctx)
    assert {:ok, %{"dry_run" => true}} = call(ctx, h, "run_command", %{command: "echo hi"})
    refute_receive {:request, _, _}, 100
  end

  test "never writes to a pane if its shell is not exclusively foreground", ctx do
    config(:live, true)
    config(:live_scenarios, [:run_command])
    Agent.update(ctx.fixture, &%{&1 | process: :busy})
    h = session(ctx)
    assert {:error, message} = call(ctx, h, "run_command", %{command: "echo hi"})
    assert message =~ "w1:p2"
    refute_receive {:request, "pane.send_input", _}, 150
  end

  test "uncertain input is not retried and reports the created pane", ctx do
    config(:live, true)
    config(:live_scenarios, [:run_command])
    Agent.update(ctx.fixture, &put_in(&1, [:fail, "pane.send_input"], :disconnect))
    h = session(ctx)
    assert {:error, message} = call(ctx, h, "run_command", %{command: "echo hi"})
    assert message =~ "w1:p2"
    assert message =~ "may"
    assert_receive {:request, "pane.send_input", _}
    assert {:error, _} = call(ctx, h, "run_command", %{command: "echo hi"})
    refute_receive {:request, "pane.send_input", _}, 150
  end

  test "spawn starts only in a checked new sibling and prompts through the prompt guard", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_spawn, :agent_prompt])
    h = session(ctx)

    assert {:ok, result} =
             call(ctx, h, "spawn_agent", %{name: "reviewer", kind: "pi", prompt: "private prompt"})

    assert result["pane_id"] == "w1:p2"
    assert result["prompt_status"] == "submitted"
    assert_receive {:request, "pane.split", _}
    assert_receive {:request, "pane.process_info", _}

    assert_receive {:request, "agent.start",
                    %{"pane_id" => "w1:p2", "name" => "reviewer", "kind" => "pi"}}

    assert_receive {:request, "agent.prompt", %{"target" => "w1:p2", "text" => "private prompt"}}
  end

  test "uncertain split is not retried", ctx do
    config(:live, true)
    config(:live_scenarios, [:run_command])
    Agent.update(ctx.fixture, &put_in(&1, [:fail, "pane.split"], :disconnect))
    h = session(ctx)
    assert {:error, message} = call(ctx, h, "run_command", %{command: "echo hi"})
    assert message =~ "may have been created"
    assert_receive {:request, "pane.split", _}
    assert {:error, _} = call(ctx, h, "run_command", %{command: "echo hi"})
    refute_receive {:request, "pane.split", _}, 150
  end

  test "returns the bounded tail rather than the start of long output", ctx do
    config(:live, true)
    config(:live_scenarios, [:run_command])
    Agent.update(ctx.fixture, &%{&1 | output: String.duplicate("x", 10_000) <> "THE-END"})
    h = session(ctx)
    assert {:ok, result} = call(ctx, h, "run_command", %{command: "echo hi"})
    assert result["output"] =~ "THE-END"
    assert byte_size(result["output"]) == 4_096
    assert result["truncated"]
  end

  test "refuses input when the created pane changes occupants during preflight", ctx do
    config(:live, true)
    config(:live_scenarios, [:run_command])
    Agent.update(ctx.fixture, &%{&1 | process: :replaced})
    h = session(ctx)
    assert {:error, message} = call(ctx, h, "run_command", %{command: "echo hi"})
    assert message =~ "w1:p2"
    refute_receive {:request, "pane.send_input", _}, 150
  end

  test "does not claim an output match on a malformed response", ctx do
    config(:live, true)
    config(:live_scenarios, [:run_command])
    Agent.update(ctx.fixture, &put_in(&1, [:fail, "pane.wait_for_output"], {:delay, 1}))
    h = session(ctx)
    assert {:ok, result} = call(ctx, h, "run_command", %{command: "echo hi", wait_for: "done"})
    assert result["wait"] == "unconfirmed"
  end

  test "spawn does not silently send a prompt when prompt scenario is disabled", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_spawn])
    h = session(ctx)

    assert {:ok, result} =
             call(ctx, h, "spawn_agent", %{name: "reviewer", kind: "pi", prompt: "hello"})

    assert result["prompt_status"] == "skipped"
    refute_receive {:request, "agent.prompt", _}, 150
  end

  defp respond("session.snapshot", _, fixture, _),
    do:
      {:reply,
       %{result: %{type: "session_snapshot", snapshot: Agent.get(fixture, & &1.snapshot)}}}

  defp respond("pane.split", params, fixture, mirror) do
    pane =
      Agent.get_and_update(fixture, fn state ->
        n = state.counter + 1

        pane = %{
          "pane_id" => "w1:p#{n}",
          "workspace_id" => "w1",
          "tab_id" => "w1:t1",
          "terminal_id" => "term#{n}",
          "cwd" => params["cwd"]
        }

        {pane,
         %{state | counter: n, snapshot: Map.update!(state.snapshot, "panes", &(&1 ++ [pane]))}}
      end)

    view = GenServer.call(mirror, :get)
    GenServer.call(mirror, {:put, %{view | snapshot: Agent.get(fixture, & &1.snapshot)}})
    {:reply, %{result: %{type: "pane_info", pane: pane}}}
  end

  defp respond("pane.process_info", %{"pane_id" => pane}, fixture, _) do
    mode = Agent.get(fixture, & &1.process)

    if mode == :replaced do
      Agent.update(fixture, fn state ->
        snapshot =
          update_in(state.snapshot, ["panes", Access.at(-1), "terminal_id"], fn _ ->
            "replacement"
          end)

        %{state | snapshot: snapshot}
      end)
    end

    processes =
      if mode in [:shell, :replaced],
        do: [%{pid: 42, name: "sh"}],
        else: [%{pid: 43, name: "other"}]

    {:reply,
     %{
       result: %{
         type: "pane_process_info",
         process_info: %{
           pane_id: pane,
           shell_pid: 42,
           foreground_process_group_id: 42,
           foreground_processes: processes
         }
       }
     }}
  end

  defp respond("plugin.pane.open", _, _, _), do: {:reply, %{result: %{type: "ok"}}}
  defp respond("pane.send_input", _, _, _), do: {:reply, %{result: %{type: "ok"}}}

  defp respond("pane.wait_for_output", %{"pane_id" => pane}, _, _),
    do: {:reply, %{result: %{type: "output_matched", pane_id: pane}}}

  defp respond("pane.read", %{"pane_id" => pane}, fixture, _),
    do:
      {:reply,
       %{
         result: %{
           type: "pane_read",
           read: %{
             pane_id: pane,
             workspace_id: "w1",
             tab_id: "w1:t1",
             text: Agent.get(fixture, & &1.output),
             truncated: false
           }
         }
       }}

  defp respond("agent.start", params, fixture, mirror) do
    pane =
      Enum.find(Agent.get(fixture, & &1.snapshot["panes"]), &(&1["pane_id"] == params["pane_id"]))

    agent =
      Map.merge(Map.take(pane, ~w(pane_id workspace_id tab_id terminal_id)), %{
        "agent" => params["kind"],
        "name" => params["name"],
        "agent_status" => "idle",
        "interactive_ready" => true
      })

    snapshot =
      Agent.get_and_update(fixture, fn state ->
        snap = Map.update!(state.snapshot, "agents", &(&1 ++ [agent]))
        {snap, %{state | snapshot: snap}}
      end)

    view = GenServer.call(mirror, :get)
    GenServer.call(mirror, {:put, %{view | snapshot: snapshot}})

    pending =
      agent
      |> Map.delete("agent")
      |> Map.put("agent_status", "unknown")
      |> Map.put("launch_pending", true)

    {:reply, %{result: %{type: "agent_started", agent: pending, argv: ["pi"]}}}
  end

  defp respond("agent.prompt", _, _, _),
    do: {:reply, %{result: %{type: "agent_prompt", submitted: true}}}

  defp respond(_, _, _, _),
    do: {:reply, %{error: %{code: "unexpected_method", message: "unexpected"}}}

  defp picker_request(ctx, id, method, body \\ nil, authorized \\ true) do
    headers = if authorized, do: [{"authorization", "Bearer " <> ctx.token}], else: []
    headers = [{"content-type", "application/json"} | headers]

    req =
      Finch.build(
        method,
        "http://127.0.0.1:#{ctx.port}/picker/#{id}",
        headers,
        if(body, do: Jason.encode!(body), else: nil)
      )

    {:ok, response} = Finch.request(req, Jarvis2.ExecutionTestFinch)
    {response.status, Jason.decode!(response.body)}
  end

  defp receive_progress(_buffer, events) when length(events) >= 3, do: events

  defp receive_progress(buffer, events) do
    receive do
      {:stream_data, data} ->
        parts = String.split(buffer <> data, "\n\n")
        {complete, [rest]} = Enum.split(parts, -1)

        found =
          for part <- complete,
              line <- String.split(part, "\n"),
              String.starts_with?(line, "data:"),
              {:ok, value} <- [
                line |> String.replace_prefix("data:", "") |> String.trim() |> Jason.decode()
              ],
              is_map(value) and value["method"] == "notifications/progress",
              do: value

        receive_progress(rest, events ++ found)
    after
      2_000 -> flunk("missing progress notifications: #{inspect(events)}")
    end
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

  defp session(ctx, pane \\ "w1:p1", workspace \\ "w1") do
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

    session =
      Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "mcp-session-id", do: v end)

    headers =
      [{"mcp-session-id", session}, {"mcp-protocol-version", protocol}] ++
        if(pane, do: [{"x-herdr-pane", pane}, {"x-herdr-workspace", workspace}], else: [])

    {202, _, _} = rpc(ctx, headers, %{jsonrpc: "2.0", method: "notifications/initialized"})
    headers
  end

  defp call(ctx, headers, name, args) do
    {200, _, %{"result" => result}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })

    [%{"text" => text}] = result["content"]
    if result["isError"], do: {:error, text}, else: {:ok, Jason.decode!(text)}
  end

  defp rpc(ctx, headers, body) do
    headers = [
      {"authorization", "Bearer " <> ctx.token},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"} | headers
    ]

    req = Finch.build(:post, "http://127.0.0.1:#{ctx.port}/mcp", headers, Jason.encode!(body))
    {:ok, response} = Finch.request(req, Jarvis2.ExecutionTestFinch, receive_timeout: 30_000)

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
