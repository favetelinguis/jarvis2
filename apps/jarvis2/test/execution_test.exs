defmodule Jarvis2.ExecutionTest do
  use Jarvis2.DataCase, async: false

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
    server = start_supervised!({Bandit, plug: Jarvis2Web.Endpoint, ip: {127, 0, 0, 1}, port: 0})
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
    refute inspect(Jarvis2.Journal.recent()) =~ "private-command"
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
