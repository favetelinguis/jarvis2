defmodule Jarvis2.PromptAgentTest do
  use ExUnit.Case, async: false

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}

    def handle_call(:get, _from, %{stale_after_next: true} = view),
      do:
        {:reply, Map.delete(view, :stale_after_next),
         view |> Map.delete(:stale_after_next) |> Map.put(:stale, true)}

    def handle_call(:get, _from, view), do: {:reply, view, view}

    def handle_call(:arm_stale, _from, view),
      do: {:reply, :ok, Map.put(view, :stale_after_next, true)}

    def handle_call({:put, view}, _from, _state), do: {:reply, :ok, view}
  end

  setup do
    snapshot = %{
      "workspaces" => [%{"workspace_id" => "w1"}, %{"workspace_id" => "w2"}],
      "tabs" => [
        %{"workspace_id" => "w1", "tab_id" => "w1:t1"},
        %{"workspace_id" => "w2", "tab_id" => "w2:t1"}
      ],
      "panes" => Enum.map(1..7, &pane("w1", &1)) ++ [pane("w2", 1)],
      "agents" =>
        Enum.zip_with(1..7, ~w(alpha beta gamma delta epsilon zeta eta), &agent("w1", &1, &2)) ++
          [agent("w2", 1, "outside")],
      "layouts" => []
    }

    view = %{snapshot: snapshot, worktrees: %{}, worktree_errors: %{}, stale: false}
    {:ok, mirror} = start_supervised({Mirror, view})
    {:ok, guard} = start_supervised({Jarvis2.Herdr.PromptGuard, [name: nil]})
    {:ok, behavior} = start_supervised({Agent, fn -> :ok end})
    parent = self()

    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "prompt-#{System.unique_integer([:positive])}"
      )

    handler = fn request ->
      send(parent, {:prompt_request, request})

      case Agent.get(behavior, & &1) do
        :ok -> {:reply, %{result: %{type: "agent_prompt", submitted: true}}}
        :close -> :close
        {:error, code} -> {:reply, %{error: %{code: code, message: "simulated failure"}}}
        {:delay, delay} -> {:later, delay, %{result: %{type: "agent_prompt", submitted: true}}}
      end
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Jarvis2.Herdr.Socket, [name: nil, path: path]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    config(:mirror, mirror)
    config(:prompt_guard, guard)
    config(:herdr_socket, socket)
    config(:live, false)
    config(:live_scenarios, [])
    start_supervised!({Finch, name: Jarvis2.PromptTestFinch})

    {:ok, server} =
      start_supervised({Bandit, plug: Jarvis2Web.Endpoint, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{port: port, token: Jarvis2.Token.get(), mirror: mirror, view: view, behavior: behavior}
  end

  test "dry-run is scoped, refuses self and unsafe targets, and sends no input", ctx do
    h = session(ctx, "w1:p1", "w1")

    assert {:ok, %{"dry_run" => true, "target" => "w1:p2"}} =
             prompt(ctx, h, "beta", "Review the test", false)

    assert {:error, _} = prompt(ctx, h, "alpha", "self", false)
    assert {:error, _} = prompt(ctx, h, "outside", "cross workspace", false)
    assert {:error, _} = prompt(ctx, h, "missing", "unknown agent", false)
    assert {:error, _} = prompt(ctx, h, "gamma", "\e[31mcontrol", false)
    blocked = put_in(ctx.view, [:snapshot, "agents", Access.at(2), "agent_status"], "blocked")
    :ok = GenServer.call(ctx.mirror, {:put, blocked})
    assert {:error, _} = prompt(ctx, h, "gamma", "blocked", false)
    not_ready = put_in(ctx.view, [:snapshot, "agents", Access.at(2), "interactive_ready"], false)
    :ok = GenServer.call(ctx.mirror, {:put, not_ready})
    assert {:error, _} = prompt(ctx, h, "gamma", "not ready", false)
    starting = put_in(ctx.view, [:snapshot, "agents", Access.at(2), "launch_pending"], true)
    :ok = GenServer.call(ctx.mirror, {:put, starting})
    assert {:error, _} = prompt(ctx, h, "gamma", "starting", false)
    replaced = put_in(ctx.view, [:snapshot, "panes", Access.at(2), "terminal_id"], "new-terminal")
    :ok = GenServer.call(ctx.mirror, {:put, replaced})
    assert {:error, _} = prompt(ctx, h, "gamma", "replaced", false)

    without_optional =
      update_in(
        ctx.view,
        [:snapshot, "agents", Access.at(2)],
        &Map.delete(&1, "interactive_ready")
      )

    :ok = GenServer.call(ctx.mirror, {:put, without_optional})
    assert {:ok, %{"dry_run" => true}} = prompt(ctx, h, "gamma", "idle on older Herdr", false)
    refute_receive {:prompt_request, _}, 100
  end

  test "live mode still requires the agent_prompt scenario", ctx do
    config(:live, true)
    h = session(ctx, "w1:p1", "w1")
    assert {:ok, %{"dry_run" => true}} = prompt(ctx, h, "beta", "dry", false)
    refute_receive {:prompt_request, _}, 100
    config(:live_scenarios, [:agent_prompt])
    assert {:ok, %{"type" => "agent_prompt"}} = prompt(ctx, h, "beta", "live", false)
    assert_receive {:prompt_request, %{"method" => "agent.prompt"}}, 1_000
  end

  test "explicit live gate resolves a pane target and bounds wait without logging text",
       ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_prompt])
    h = session(ctx, "w1:p1", "w1")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{"type" => "agent_prompt"}} =
                 prompt(ctx, h, "beta", "private task text", true)

        assert_receive {:prompt_request,
                        %{
                          "method" => "agent.prompt",
                          "params" => %{
                            "target" => "w1:p2",
                            "text" => "private task text",
                            "wait" => %{"timeout_ms" => 60_000}
                          }
                        }},
                       1_000
      end)

    refute log =~ "private task text"
    refute inspect(Jarvis2.State.recent_journal()) =~ "private task text"
  end

  test "rejects indirect prompt cycles and missing or stale caller identity", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_prompt])
    a = session(ctx, "w1:p1", "w1")
    b = session(ctx, "w1:p2", "w1")
    c = session(ctx, "w1:p3", "w1")
    unknown = session(ctx, nil, nil)
    assert {:ok, _} = prompt(ctx, a, "beta", "one", false)
    assert {:ok, _} = prompt(ctx, b, "gamma", "two", false)
    assert {:error, message} = prompt(ctx, c, "alpha", "loop", false)
    assert message =~ "cycle"
    assert {:error, _} = prompt(ctx, unknown, "beta", "unknown caller", false)
    assert_receive {:prompt_request, _}
    assert_receive {:prompt_request, _}
    refute_receive {:prompt_request, _}, 100
    GenServer.call(ctx.mirror, :arm_stale)
    assert {:error, _} = prompt(ctx, a, "delta", "stale", false)
    refute_receive {:prompt_request, _}, 100
  end

  test "rate limits a caller across distinct targets", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_prompt])
    h = session(ctx, "w1:p1", "w1")

    for target <- ~w(beta gamma delta epsilon),
        do: assert({:ok, _} = prompt(ctx, h, target, "task", false))

    assert {:error, message} = prompt(ctx, h, "zeta", "too many", false)
    assert message =~ "rate"
    for _ <- 1..4, do: assert_receive({:prompt_request, _})
    refute_receive {:prompt_request, _}, 100
  end

  test "enforces the per-caller rate limit atomically across concurrent targets", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_prompt])
    Agent.update(ctx.behavior, fn _ -> {:delay, 100} end)
    headers = Enum.map(1..6, fn _ -> session(ctx, "w1:p1", "w1") end)

    tasks =
      Enum.zip(headers, ~w(beta gamma delta epsilon zeta eta))
      |> Enum.map(fn {header, target} ->
        Task.async(fn -> prompt(ctx, header, target, "task", false) end)
      end)

    results = Enum.map(tasks, &Task.await(&1, 3_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 4
    assert Enum.count(results, &match?({:error, "prompt rejected: rate_limited"}, &1)) == 2
    for _ <- 1..4, do: assert_receive({:prompt_request, _})
    refute_receive {:prompt_request, _}, 100
  end

  test "serializes concurrent prompts to the same target", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_prompt])
    Agent.update(ctx.behavior, fn _ -> {:delay, 350} end)
    a = session(ctx, "w1:p1", "w1")
    c = session(ctx, "w1:p3", "w1")
    first = Task.async(fn -> prompt(ctx, a, "beta", "first", false) end)
    assert_receive {:prompt_request, _}, 1_000
    assert {:error, _} = prompt(ctx, c, "beta", "second", false)
    assert {:ok, _} = Task.await(first, 2_000)
    refute_receive {:prompt_request, _}, 100
  end

  test "a disconnected prompt is not retried and reports uncertain delivery", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_prompt])
    Agent.update(ctx.behavior, fn _ -> :close end)
    h = session(ctx, "w1:p1", "w1")
    assert {:error, message} = prompt(ctx, h, "beta", "once", false)
    assert message =~ "may have been submitted"
    assert_receive {:prompt_request, _}, 1_000
    assert {:error, message} = prompt(ctx, h, "beta", "do not retry", false)
    assert message =~ "target_busy"
    target = session(ctx, "w1:p2", "w1")
    assert {:error, message} = prompt(ctx, target, "alpha", "reverse after timeout", false)
    assert message =~ "cycle"
    refute_receive {:prompt_request, _}, 150
  end

  test "Herdr can still reject an apparently idle target", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_prompt])
    Agent.update(ctx.behavior, fn _ -> {:error, "agent_not_ready"} end)
    h = session(ctx, "w1:p1", "w1")
    assert {:error, message} = prompt(ctx, h, "beta", "task", false)
    assert message =~ "agent_not_ready"
    assert_receive {:prompt_request, _}, 1_000
    refute_receive {:prompt_request, _}, 100
  end

  test "an unavailable guard refuses to send input", ctx do
    config(:live, true)
    config(:live_scenarios, [:agent_prompt])
    h = session(ctx, "w1:p1", "w1")
    config(:prompt_guard, :missing_prompt_guard)
    assert {:error, message} = prompt(ctx, h, "beta", "task", false)
    assert message =~ "guard_unavailable"
    refute_receive {:prompt_request, _}, 100
  end

  defp pane(workspace, n),
    do: %{
      "pane_id" => "#{workspace}:p#{n}",
      "workspace_id" => workspace,
      "tab_id" => "#{workspace}:t1",
      "terminal_id" => "#{workspace}-term#{n}",
      "cwd" => File.cwd!()
    }

  defp agent(workspace, n, name),
    do: %{
      "pane_id" => "#{workspace}:p#{n}",
      "workspace_id" => workspace,
      "tab_id" => "#{workspace}:t1",
      "terminal_id" => "#{workspace}-term#{n}",
      "agent" => "pi",
      "name" => name,
      "agent_status" => "idle",
      "interactive_ready" => true,
      "launch_pending" => false
    }

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

  defp session(ctx, pane, workspace) do
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

  defp prompt(ctx, headers, target, text, wait) do
    {200, _, %{"result" => result}} =
      rpc(ctx, headers, %{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: %{name: "prompt_agent", arguments: %{agent: target, text: text, wait: wait}}
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

    request = Finch.build(:post, "http://127.0.0.1:#{ctx.port}/mcp", headers, Jason.encode!(body))
    {:ok, response} = Finch.request(request, Jarvis2.PromptTestFinch, receive_timeout: 30_000)

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
