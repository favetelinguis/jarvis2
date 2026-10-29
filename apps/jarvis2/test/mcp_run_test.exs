defmodule Jarvis2.MCPRunTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.{Journal, Questions, Runs, Tokens}
  alias Jarvis2.Runs.Run

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
  end

  setup do
    {:ok, mirror} = start_supervised({Mirror, view()})
    previous = Application.fetch_env(:jarvis2, :mirror)
    Application.put_env(:jarvis2, :mirror, mirror)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:jarvis2, :mirror, v)
        :error -> Application.delete_env(:jarvis2, :mirror)
      end
    end)

    # A private guard keeps these dry-run launches out of the shared per-minute rate limit.
    guard = start_supervised!({Jarvis2.Herdr.ExecutionGuard, [name: nil]})
    config(:execution_guard, guard)

    start_supervised!({Finch, name: Jarvis2.MCPRunFinch})

    {:ok, server} =
      start_supervised({Bandit, plug: Jarvis2Web.Endpoint, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    run = working_run("first", "term-run")
    {:ok, token} = Tokens.mint_for_run(run.id)
    %{port: port, run: run, token: token}
  end

  test "a run token resolves to the run's pane without any identity headers", ctx do
    session = start_session(ctx, ctx.token)
    me = call(ctx, session, "whoami", %{})

    assert me["run_id"] == ctx.run.id
    assert me["pane"] == "w1:p9"
    assert me["workspace"] == "w1"
    assert me["agent_name"] == "run-agent"
    assert me["mismatch"] == false
  end

  test "ask_human returns a ticket and a human answer unblocks wait_for_answer", ctx do
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, Questions.topic())
    session = start_session(ctx, ctx.token)

    ticket = call(ctx, session, "ask_human", %{prompt: "Which file?", options: ["a.ex", "b.ex"]})
    assert %{"status" => "pending", "ticket" => id} = ticket
    assert_receive {:question, %{id: ^id, kind: :question, run_id: run_id}}
    assert run_id == ctx.run.id

    assert %{"status" => "pending"} =
             call(ctx, session, "wait_for_answer", %{ticket: id, timeout_s: 1})

    waiter =
      Task.async(fn -> call(ctx, session, "wait_for_answer", %{ticket: id, timeout_s: 20}) end)

    Process.sleep(100)
    {:ok, _} = Questions.answer(Questions.get(id), "b.ex")
    assert %{"status" => "answered", "answer" => "b.ex"} = Task.await(waiter, 5_000)
  end

  test "request_approval is an approve/deny question", ctx do
    session = start_session(ctx, ctx.token)

    %{"ticket" => id} =
      call(ctx, session, "request_approval", %{action: "delete build/", detail: "frees 2GB"})

    question = Questions.get(id)
    assert question.kind == :approval
    assert question.options == ["approve", "deny"]
    assert question.detail == "frees 2GB"
    assert {:error, :invalid_answer} = Questions.answer(question, "sure")
    {:ok, _} = Questions.answer(question, "deny")

    assert %{"status" => "answered", "answer" => "deny"} =
             call(ctx, session, "wait_for_answer", %{ticket: id, timeout_s: 1})
  end

  test "agents cannot read another run's tickets or flood the inbox", ctx do
    session = start_session(ctx, ctx.token)
    %{"ticket" => id} = call(ctx, session, "ask_human", %{prompt: "mine"})

    other = working_run("second", "term-other")
    {:ok, other_token} = Tokens.mint_for_run(other.id)
    other_session = start_session(ctx, other_token)

    assert {:error, "unknown ticket"} =
             call_error(ctx, other_session, "wait_for_answer", %{ticket: id, timeout_s: 1})

    for _ <- 1..4, do: call(ctx, session, "ask_human", %{prompt: "more"})

    assert {:error, "too many open questions" <> _} =
             call_error(ctx, session, "ask_human", %{prompt: "one too many"})
  end

  test "run-only tools are refused for callers without a run token", ctx do
    session = start_session(ctx, Jarvis2.Token.get())

    for {tool, args} <- [
          {"ask_human", %{prompt: "x"}},
          {"request_approval", %{action: "x"}},
          {"wait_for_answer", %{ticket: "x"}},
          {"submit_result", %{summary: "x"}}
        ] do
      assert {:error, "this tool requires a run token"} = call_error(ctx, session, tool, args)
    end
  end

  test "report_status updates the run and keeps the summary for the user", ctx do
    session = start_session(ctx, ctx.token)

    assert %{"run_status" => "blocked"} =
             call(ctx, session, "report_status", %{state: "blocked", summary: "need a decision"})

    assert Runs.get_run(ctx.run.id).status == :blocked

    event = Enum.find(Journal.recent(run_id: ctx.run.id), &(&1.type == "run.report"))
    assert event.payload == %{"state" => "blocked", "status_summary" => "need a decision"}

    assert {:error, _} =
             call_error(ctx, session, "report_status", %{
               state: "blocked",
               summary: String.duplicate("x", 257)
             })
  end

  test "submit_result finishes the run, cancels open questions and revokes the token", ctx do
    session = start_session(ctx, ctx.token)
    %{"ticket" => id} = call(ctx, session, "ask_human", %{prompt: "still open"})

    assert %{"status" => "done"} =
             call(ctx, session, "submit_result", %{summary: "All done", artifacts: ["report.md"]})

    run = Runs.get_run(ctx.run.id)

    assert %Run{
             status: :done,
             finished_at: %DateTime{},
             result: %{"summary" => "All done", "artifacts" => ["report.md"]}
           } = run

    assert %{status: :cancelled} = Questions.get(id)
    assert Tokens.resolve(ctx.token) == :error
    assert {401, _} = raw_post(ctx, ctx.token)
  end

  test "stopping or losing a run revokes its token", ctx do
    Runs.stop_run(Runs.get_run(ctx.run.id)) |> then(&assert({:ok, %{status: :stopped}} = &1))
    assert Tokens.resolve(ctx.token) == :error
  end

  test "unknown run tokens are rejected before any tool runs", ctx do
    assert {401, _} = raw_post(ctx, "j2r_garbage")
    assert {401, _} = raw_post(ctx, "wrong")
    assert {401, _} = raw_post(ctx, nil)
  end

  test "a pane header that disagrees with the run is refused for write tools only", ctx do
    session =
      start_session(ctx, ctx.token, [{"x-herdr-pane", "w1:p1"}, {"x-herdr-workspace", "w1"}])

    assert call(ctx, session, "whoami", %{})["mismatch"] == true

    assert {:error, "caller identity does not match" <> _} =
             call_error(ctx, session, "ask_human", %{prompt: "x"})

    assert {:error, _} = call_error(ctx, session, "blackboard_put", %{key: "k", value: 1})
    assert Questions.list_pending() == []
  end

  test "tool calls are journalled against the run", ctx do
    session = start_session(ctx, ctx.token)
    call(ctx, session, "ask_human", %{prompt: "journal me"})

    assert Enum.any?(
             Journal.recent(run_id: ctx.run.id),
             &(&1.type == "tool.ask_human" and &1.source == :mcp)
           )

    refute inspect(Journal.recent()) =~ "journal me"
  end

  test "a dry-run start never mints a token" do
    config(:live, false)
    config(:live_scenarios, [])
    Repo.delete_all(Jarvis2.Tokens.ApiToken)
    {:ok, run} = Runs.create_run(%{name: "dry", task: "t", cwd: File.cwd!()})
    Runs.launch(run)
    assert Repo.aggregate(Jarvis2.Tokens.ApiToken, :count) == 0

    event = Enum.find(Journal.recent(run_id: run.id), &(&1.type == "run.start"))
    [split | _] = event.payload["planned"]
    assert "JARVIS2_RUN_TOKEN" in split["params"]["env_keys"]
  end

  # --- helpers

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

  defp working_run(name, terminal) do
    {:ok, run} = Runs.create_run(%{name: name, task: "t", cwd: File.cwd!()})

    {:ok, run} =
      run
      |> Run.progress_changeset(%{
        status: :working,
        pane_id: pane_for(terminal),
        terminal_id: terminal,
        agent_name: "run-agent"
      })
      |> Repo.update()

    run
  end

  defp pane_for("term-run"), do: "w1:p9"
  defp pane_for(_), do: "w1:p8"

  defp view do
    panes =
      for {id, terminal} <- [
            {"w1:p1", "term-anchor"},
            {"w1:p9", "term-run"},
            {"w1:p8", "term-other"}
          ],
          do: %{
            "pane_id" => id,
            "workspace_id" => "w1",
            "tab_id" => "w1:t1",
            "terminal_id" => terminal,
            "cwd" => File.cwd!()
          }

    agents =
      for pane <- panes,
          pane["pane_id"] != "w1:p1",
          do:
            Map.merge(pane, %{
              "agent" => "pi",
              "name" => "run-agent",
              "agent_status" => "working",
              "interactive_ready" => true
            })

    %{
      stale: false,
      worktrees: %{},
      worktree_errors: %{},
      layout_diff: nil,
      snapshot: %{
        "workspaces" => [%{"workspace_id" => "w1"}],
        "tabs" => [%{"workspace_id" => "w1", "tab_id" => "w1:t1"}],
        "panes" => panes,
        "agents" => agents,
        "layouts" => []
      }
    }
  end

  defp start_session(ctx, token, extra \\ []) do
    {200, headers, %{"result" => %{"protocolVersion" => protocol}}} =
      rpc(ctx, token, [], %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-11-25",
          capabilities: %{},
          clientInfo: %{name: "t", version: "1"}
        }
      })

    id =
      Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "mcp-session-id", do: v end)

    session = %{
      token: token,
      headers: [{"mcp-session-id", id}, {"mcp-protocol-version", protocol} | extra]
    }

    {202, _, _} =
      rpc(ctx, token, session.headers, %{jsonrpc: "2.0", method: "notifications/initialized"})

    session
  end

  defp call(ctx, session, name, args) do
    case tool(ctx, session, name, args) do
      {:ok, text} -> Jason.decode!(text)
      {:error, message} -> flunk("#{name} failed: #{message}")
    end
  end

  defp call_error(ctx, session, name, args) do
    case tool(ctx, session, name, args) do
      {:error, message} -> {:error, message}
      {:ok, text} -> flunk("#{name} unexpectedly succeeded: #{text}")
    end
  end

  defp tool(ctx, session, name, args) do
    {200, _, %{"result" => %{"content" => [%{"text" => text}], "isError" => error?}}} =
      rpc(ctx, session.token, session.headers, %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{name: name, arguments: args}
      })

    if error?, do: {:error, text}, else: {:ok, text}
  end

  defp raw_post(ctx, token) do
    {status, _, body} = rpc(ctx, token, [], %{jsonrpc: "2.0", id: 1, method: "initialize"})
    {status, body}
  end

  defp rpc(ctx, token, headers, request) do
    auth = if token, do: [{"authorization", "Bearer " <> token}], else: []

    headers =
      auth ++
        [
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"} | headers
        ]

    request =
      Finch.build(:post, "http://127.0.0.1:#{ctx.port}/mcp", headers, Jason.encode!(request))

    {:ok, response} = Finch.request(request, Jarvis2.MCPRunFinch, receive_timeout: 30_000)

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
          case Jason.decode(response.body) do
            {:ok, decoded} -> decoded
            _ -> response.body
          end
      end

    {response.status, response.headers, body}
  end
end
