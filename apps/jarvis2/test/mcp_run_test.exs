defmodule Jarvis2.MCPRunTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.{Journal, Questions, Runs}
  alias Jarvis2.Runs.Run

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
    def handle_call({:put, view}, _from, _), do: {:reply, :ok, view}
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

    # Keep execution attempts out of the shared per-minute rate limit.
    guard = start_supervised!({Jarvis2.Herdr.ExecutionGuard, [name: nil]})
    config(:execution_guard, guard)

    start_supervised!({Finch, name: Jarvis2.MCPRunFinch})

    {:ok, server} =
      start_supervised({Bandit, plug: Jarvis2Web.Endpoint, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    run = working_run("first", "term-run")
    %{port: port, run: run, pane: "w1:p9", mirror: mirror}
  end

  test "a pane header resolves to its run", ctx do
    session = start_session(ctx, ctx.pane)
    me = call(ctx, session, "whoami", %{})

    assert me["run_id"] == ctx.run.id
    assert me["pane"] == "w1:p9"
    assert me["workspace"] == "w1"
    assert me["agent_name"] == "run-agent"
  end

  test "run lookup needs only the pane header", ctx do
    session = start_session(ctx, {ctx.pane, nil})
    assert %{"run_id" => id, "pane" => "unknown"} = call(ctx, session, "whoami", %{})
    assert id == ctx.run.id
    assert %{"ticket" => _} = call(ctx, session, "ask_human", %{prompt: "pane only"})
  end

  test "ask_human returns a ticket and a human answer unblocks wait_for_answer", ctx do
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, Questions.topic())
    session = start_session(ctx, ctx.pane)

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
    session = start_session(ctx, ctx.pane)

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
    session = start_session(ctx, ctx.pane)
    %{"ticket" => id} = call(ctx, session, "ask_human", %{prompt: "mine"})

    working_run("second", "term-other")
    other_session = start_session(ctx, "w1:p8")

    assert {:error, "unknown ticket"} =
             call_error(ctx, other_session, "wait_for_answer", %{ticket: id, timeout_s: 1})

    for _ <- 1..4, do: call(ctx, session, "ask_human", %{prompt: "more"})

    assert {:error, "too many open questions" <> _} =
             call_error(ctx, session, "ask_human", %{prompt: "one too many"})
  end

  test "run-only tools are refused for an unknown pane", ctx do
    session = start_session(ctx, "w1:unknown")

    for {tool, args} <- [
          {"ask_human", %{prompt: "x"}},
          {"request_approval", %{action: "x"}},
          {"wait_for_answer", %{ticket: "x"}},
          {"submit_result", %{summary: "x"}},
          {"ask_questions", %{questions: [%{title: "x", body: "x", recommended: "x"}]}},
          {"submit_deliverable", %{content: "x"}}
        ] do
      assert {:error, "no run for this pane"} = call_error(ctx, session, tool, args)
    end

    assert {:error, "Not a kanban run."} =
             call_error(ctx, session, "report_skill", %{name: "x", reason: "x"})
  end

  test "report_skill records valid reports for kanban runs and enforces limits", ctx do
    session = start_session(ctx, ctx.pane)

    assert {:error, "Not a kanban run."} =
             call_error(ctx, session, "report_skill", %{name: "review", reason: "Review changes"})

    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Idea", cwd: File.cwd!()})
    card |> Ecto.Changeset.change(column: :agent, run_id: ctx.run.id) |> Repo.update!()

    assert {:error, _} = call_error(ctx, session, "report_skill", %{name: " ", reason: "ok"})

    assert {:error, _} =
             call_error(ctx, session, "report_skill", %{
               name: "skill",
               reason: String.duplicate("é", 251)
             })

    for n <- 1..50 do
      assert %{"status" => "recorded"} =
               call(ctx, session, "report_skill", %{name: "skill-#{n}", reason: "needed"})
    end

    assert {:error, _} =
             call_error(ctx, session, "report_skill", %{name: "extra", reason: "loop"})

    uses = Jarvis2.Kanban.get_card(card.id).skill_uses
    assert length(uses) == 50
    assert Enum.all?(uses, &(&1.stage == :planning and &1.run_id == ctx.run.id))
    assert Jarvis2.Kanban.get_card(card.id).column == :agent
    refute inspect(Journal.recent(type: "tool.report_skill")) =~ "needed"
  end

  test "submit_result keeps the pane usable until the run is stopped", ctx do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "stop-#{System.unique_integer([:positive])}"
      )

    parent = self()

    {:ok, _, listener} =
      Jarvis2.Test.FakeHerdr.start_link(path, fn request ->
        send(parent, {:close_request, request})
        {:reply, %{result: %{type: "ok"}}}
      end)

    socket = start_supervised!({Jarvis2.Herdr.Socket, [path: path, name: nil]})
    config(:herdr_socket, socket)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    session = start_session(ctx, ctx.pane)
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
    assert %{"ticket" => _} = call(ctx, session, "ask_human", %{prompt: "follow up"})
    assert {:ok, %{status: :stopped}} = Runs.stop_run(run)

    assert_receive {:close_request,
                    %{"method" => "pane.close", "params" => %{"pane_id" => "w1:p9"}}}

    assert {:error, "no run for this pane"} =
             call_error(ctx, session, "ask_human", %{prompt: "too late"})
  end

  test "stale mirror allows run lookup, but a recycled terminal does not", ctx do
    session = start_session(ctx, ctx.pane)
    :ok = GenServer.call(ctx.mirror, {:put, %{view() | stale: true}})
    assert %{"run_id" => id, "pane" => "unknown"} = call(ctx, session, "whoami", %{})
    assert id == ctx.run.id
    assert %{"ticket" => _} = call(ctx, session, "ask_human", %{prompt: "stale"})

    recycled =
      update_in(view(), [:snapshot, "panes"], fn panes ->
        Enum.map(panes, fn pane ->
          if pane["pane_id"] == "w1:p9", do: Map.put(pane, "terminal_id", "new"), else: pane
        end)
      end)

    :ok = GenServer.call(ctx.mirror, {:put, recycled})

    assert {:error, "no run for this pane"} =
             call_error(ctx, session, "ask_human", %{prompt: "x"})
  end

  test "failed and lost runs no longer resolve", ctx do
    session = start_session(ctx, ctx.pane)

    for status <- [:failed, :lost] do
      ctx.run |> Run.progress_changeset(%{status: status}) |> Repo.update!()

      assert {:error, "no run for this pane"} =
               call_error(ctx, session, "ask_human", %{prompt: "x"})
    end
  end

  test "tool calls are journalled against the run", ctx do
    session = start_session(ctx, ctx.pane)
    call(ctx, session, "ask_human", %{prompt: "journal me"})

    assert Enum.any?(
             Journal.recent(run_id: ctx.run.id),
             &(&1.type == "tool.ask_human" and &1.source == :mcp)
           )

    refute inspect(Journal.recent()) =~ "journal me"
  end

  test "kanban tools validate input and keep interview text out of the journal", ctx do
    session = start_session(ctx, ctx.pane)

    question = %{
      title: "secret title",
      body: "secret body",
      recommended: "secret recommendation",
      options: ["secret option"]
    }

    assert {:error, "Not a kanban run."} =
             call_error(ctx, session, "ask_questions", %{questions: [question]})

    {:ok, card} = Jarvis2.Kanban.create_card(%{title: "Board", cwd: File.cwd!(), kind: :explain})
    card |> Ecto.Changeset.change(column: :agent, run_id: ctx.run.id) |> Repo.update!()

    assert {:error, _} =
             call_error(ctx, session, "ask_questions", %{questions: List.duplicate(question, 3)})

    assert %{"round" => 1, "status" => "awaiting_user"} =
             call(ctx, session, "ask_questions", %{questions: [question]})

    assert {:error, _} = call_error(ctx, session, "ask_questions", %{questions: [question]})

    assert %{"status" => "done"} =
             call(ctx, session, "submit_deliverable", %{content: "secret final plan"})

    assert Jarvis2.Kanban.get_card(card.id).column == :done
    refute inspect(Journal.recent()) =~ "secret"
  end

  test "removed submit_plan is rejected without journalling its text", ctx do
    session = start_session(ctx, ctx.pane)

    {200, _, response} =
      rpc(ctx, session.pane, session.headers, %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "submit_plan", arguments: %{plan: "secret old plan text"}}
      })

    assert response["error"] || get_in(response, ["result", "isError"])
    refute inspect(Journal.recent()) =~ "secret old plan text"
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

  defp start_session(ctx, pane) do
    {200, headers, %{"result" => %{"protocolVersion" => protocol}}} =
      rpc(ctx, pane, [], %{
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
      pane: pane,
      headers: [{"mcp-session-id", id}, {"mcp-protocol-version", protocol}]
    }

    {202, _, _} =
      rpc(ctx, pane, session.headers, %{jsonrpc: "2.0", method: "notifications/initialized"})

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
      rpc(ctx, session.pane, session.headers, %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{name: name, arguments: args}
      })

    if error?, do: {:error, text}, else: {:ok, text}
  end

  defp rpc(ctx, pane, headers, request) do
    identity =
      case pane do
        {id, nil} -> [{"x-herdr-pane", id}]
        id -> [{"x-herdr-pane", id}, {"x-herdr-workspace", "w1"}]
      end

    headers =
      identity ++
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
