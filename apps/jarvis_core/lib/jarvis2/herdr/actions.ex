defmodule Jarvis2.Herdr.Actions do
  @moduledoc "Single entry point for Herdr mutations, gated by live mode and scenario."
  require Logger
  alias Jarvis2.Herdr.{Client, ExecutionGuard, Mirror, PromptGuard, Socket}

  # Agent-facing execution cannot bypass its dedicated policy through call/4.
  @guarded_methods ~w(agent.prompt agent.start agent.send_keys pane.run pane.send_input pane.send_text pane.send_keys)

  def call(scenario, method, params, opts \\ [])
      when is_atom(scenario) and is_binary(method) and is_map(params) do
    caller = Keyword.get(opts, :caller, "unknown")

    if Application.get_env(:jarvis2, :live, false) and
         scenario in Application.get_env(:jarvis2, :live_scenarios, []) do
      if method in @guarded_methods do
        Logger.warning(
          "Herdr live #{inspect(scenario)} #{inspect(method)} caller=#{inspect(caller)} refused: guarded execution requires a dedicated path"
        )

        {:error,
         %{
           code: "guard_unavailable",
           message: "guarded execution is unavailable through Actions.call"
         }}
      else
        result = Socket.request(method, params, opts)

        Logger.info(
          "Herdr live #{inspect(scenario)} #{inspect(method)} caller=#{inspect(caller)} outcome=#{outcome(result)}"
        )

        result
      end
    else
      Logger.info(
        "would call #{inspect(method)} scenario=#{inspect(scenario)} caller=#{inspect(caller)} parameter_keys=#{inspect(Map.keys(params))}"
      )

      {:ok, %{dry_run: true}}
    end
  end

  def prompt(caller, target, text, wait, opts \\ []) do
    guard = Application.get_env(:jarvis2, :prompt_guard, PromptGuard)

    live =
      Application.get_env(:jarvis2, :live, false) and
        :agent_prompt in Application.get_env(:jarvis2, :live_scenarios, [])

    mode = if live, do: :live, else: :dry

    if valid_prompt?(target, text, wait) do
      case PromptGuard.reserve(caller, target, mode, guard) do
        {:ok, pane, lease} ->
          params =
            if wait,
              do: %{target: pane, text: text, wait: %{timeout_ms: 60_000}},
              else: %{target: pane, text: text}

          result =
            try do
              if live do
                result =
                  Socket.request(
                    "agent.prompt",
                    params,
                    Keyword.put(opts, :timeout, if(wait, do: 65_000, else: 5_000))
                  )

                Logger.info(
                  "Herdr live :agent_prompt \"agent.prompt\" caller=#{inspect(caller.pane)} outcome=#{outcome(result)}"
                )

                result
              else
                Logger.info(
                  "would call \"agent.prompt\" scenario=:agent_prompt caller=#{inspect(caller.pane)} parameter_keys=#{inspect(Map.keys(params))}"
                )

                {:ok, %{dry_run: true, target: pane}}
              end
            rescue
              _ -> {:error, %{code: "disconnected"}}
            catch
              :exit, _ -> {:error, %{code: "disconnected"}}
            end

          PromptGuard.finish(
            lease,
            if(match?({:ok, _}, result), do: :ok, else: :uncertain),
            guard
          )

          result

        error ->
          error
      end
    else
      {:error, %{code: "invalid_prompt"}}
    end
  end

  @agent_kinds ~w(pi claude codex gemini cursor devin agy cline omp mastracode opencode copilot kimi kiro droid amp grok hermes kilo qodercli qwen letta maki muse)

  def spawn_agent(caller, args, opts \\ []) do
    name = args[:name]
    kind = args[:kind]
    prompt_text = args[:prompt]

    if is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,31}\z/, name) and
         kind in @agent_kinds and valid_cwd?(args[:cwd], caller) and
         (is_nil(prompt_text) or valid_prompt?("target", prompt_text, false)) do
      execute(:agent_spawn, caller, args[:cwd], opts, fn verified, socket ->
        with {:ok, pane} <- create_execution_pane(verified, socket),
             {:ok, _} <- start_agent(pane, name, kind, execution_scope(verified), socket) do
          prompt_status = maybe_prompt_new_agent(verified, pane, prompt_text, socket)
          {:ok, %{pane_id: pane["pane_id"], name: name, kind: kind, prompt_status: prompt_status}}
        end
      end)
    else
      {:error, "invalid agent name, kind, or prompt"}
    end
  end

  @task_statuses ["idle", "done", "working", "blocked"]

  @doc """
  Creates a linked worktree workspace from `source.workspace` and starts an agent in it.

  `source` is a human context already resolved against a fresh mirror. The initial
  prompt is passed as a single launch argument (verified for `pi`), so no prompt
  to a running agent is needed. A failed or uncertain step is never retried.
  """
  def create_task(source, args, opts \\ []) do
    slug = args[:slug]
    kind = args[:kind]
    prompt_text = args[:prompt]
    socket = Keyword.get(opts, :server, Application.get_env(:jarvis2, :herdr_socket, Socket))

    if is_map(source) and is_binary(source[:workspace]) and is_binary(slug) and
         Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,39}\z/, slug) and kind in @agent_kinds and
         (is_nil(prompt_text) or valid_terminal_text?(prompt_text, 1_024)) do
      if live?(:worktree_task) and live?(:agent_spawn) do
        do_create_task(source, slug, kind, prompt_text, socket)
      else
        Logger.info(
          "would create a worktree task scenario=:worktree_task caller=#{inspect(source[:pane])}"
        )

        {:ok, %{dry_run: true}}
      end
    else
      {:error, "invalid task"}
    end
  end

  defp do_create_task(source, slug, kind, prompt_text, socket) do
    name = ("task-" <> slug) |> String.slice(0, 32) |> String.trim_trailing("-")

    with {:ok, repo_key} <- task_source(source, socket),
         {:ok, created} <- create_worktree(source, slug, repo_key, socket),
         :ok <- await_task_shell(created, socket) do
      scope = %{
        workspace: created.workspace,
        tab: created.tab,
        pane: source.pane,
        statuses: @task_statuses,
        valid?: fn view -> task_pane(view, created) != nil end
      }

      pane = %{"pane_id" => created.pane, "terminal_id" => created.terminal}
      args = if prompt_text, do: [prompt_text], else: []

      case start_agent(pane, name, kind, scope, socket, args) do
        {:ok, _} ->
          {:ok,
           %{
             workspace_id: created.workspace,
             pane_id: created.pane,
             branch: "task/" <> slug,
             agent: name,
             kind: kind
           }}

        {:error, message} ->
          {:error, message <> " (workspace #{created.workspace})"}
      end
    end
  end

  # Snapshots and `workspace.list` do not reliably carry worktree provenance;
  # `worktree.list` resolves the repository for any workspace inside one.
  defp task_source(source, socket) do
    with {:ok, %{"source" => %{"repo_key" => repo_key}}} when is_binary(repo_key) <-
           Client.list_worktrees(source.workspace, server: socket, timeout: 5_000),
         {:ok, %{"snapshot" => %{"panes" => panes}}} when is_list(panes) <-
           Client.snapshot(server: socket, timeout: 5_000),
         true <-
           Enum.any?(
             panes,
             &(is_map(&1) and &1["pane_id"] == source.pane and
                 &1["workspace_id"] == source.workspace)
           ) do
      {:ok, repo_key}
    else
      _ -> {:error, "source workspace is unavailable or is not a Git worktree workspace"}
    end
  end

  defp create_worktree(source, slug, repo_key, socket) do
    params = %{workspace_id: source.workspace, branch: "task/" <> slug, label: slug, focus: false}

    params =
      case Application.get_env(:jarvis2, :worktree_root) do
        root when is_binary(root) ->
          Map.put(params, :path, Path.join([Path.expand(root), repo_name(repo_key), slug]))

        _ ->
          params
      end

    result = Socket.request("worktree.create", params, server: socket, timeout: 30_000)

    Logger.info(
      "Herdr live :worktree_task \"worktree.create\" caller=#{inspect(source.pane)} outcome=#{outcome(result)}"
    )

    case result do
      {:ok,
       %{
         "type" => "worktree_created",
         "workspace" => %{
           "workspace_id" => id,
           "active_tab_id" => tab,
           "worktree" => %{"repo_key" => ^repo_key} = tree
         },
         "root_pane" => %{"pane_id" => pane, "terminal_id" => terminal, "workspace_id" => id}
       }}
      when is_binary(id) and is_binary(tab) and is_binary(pane) and is_binary(terminal) ->
        if tree["is_linked_worktree"] == true,
          do: {:ok, %{workspace: id, tab: tab, pane: pane, terminal: terminal}},
          else: {:error, "worktree workspace #{id} is not a linked worktree; inspect it"}

      {:ok, _} ->
        {:error, "worktree may have been created; inspect the workspaces before retrying"}

      {:error, %{code: code}} when code in ["timeout", "disconnected"] ->
        {:error, "worktree may have been created; inspect the workspaces before retrying"}

      {:error, _} ->
        {:error, "worktree creation was rejected"}
    end
  end

  defp repo_name(repo_key) do
    repo_key
    |> String.trim_trailing("/.git")
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  defp task_pane(%{snapshot: %{"panes" => panes}}, created) when is_list(panes) do
    with [pane] <- Enum.filter(panes, &(is_map(&1) and &1["pane_id"] == created.pane)),
         true <-
           pane["terminal_id"] == created.terminal and pane["workspace_id"] == created.workspace and
             pane["tab_id"] == created.tab do
      pane
    else
      _ -> nil
    end
  end

  defp task_pane(_, _), do: nil

  defp await_task_shell(created, socket) do
    with {:ok, %{"snapshot" => %{"agents" => agents} = snapshot}} when is_list(agents) <-
           Client.snapshot(server: socket, timeout: 5_000),
         pane when is_map(pane) <- task_pane(%{snapshot: snapshot}, created),
         true <- Enum.all?(agents, &(is_map(&1) and &1["pane_id"] != pane["pane_id"])),
         :ok <- await_shell(created.pane, socket, System.monotonic_time(:millisecond) + 5_000) do
      :ok
    else
      _ ->
        {:error, "worktree workspace #{created.workspace} is not safely available; inspect it"}
    end
  end

  @doc """
  Starts one reviewer agent per focus in sibling panes of a human-resolved `source` pane and
  collects each reviewer's final output.

  Reviewers receive their instruction as a launch argument. They are told to review only;
  this does not stop an agent from editing files, so run it where that is acceptable.
  Waiting is best-effort: an output that arrives after `timeout_s` is returned as `timeout`.
  """
  def review_fanout(source, args, opts \\ []) do
    focuses = args[:focuses]
    kind = args[:kind]
    timeout_s = args[:timeout_s] || 300
    socket = Keyword.get(opts, :server, Application.get_env(:jarvis2, :herdr_socket, Socket))
    source = Map.put(source, :human, true)

    if is_list(focuses) and length(focuses) in 1..3 and
         Enum.all?(focuses, &(is_binary(&1) and Regex.match?(~r/\A[a-z][a-z0-9-]{0,19}\z/, &1))) and
         length(Enum.uniq(focuses)) == length(focuses) and kind in @agent_kinds and
         is_integer(timeout_s) and timeout_s in 10..900 do
      if live?(:review_fanout) and live?(:agent_spawn) do
        scope = %{
          workspace: source.workspace,
          tab: source.tab,
          pane: source.pane,
          statuses: @task_statuses,
          valid?: fn view -> match?({:ok, _}, validate_source(source, view)) end
        }

        started = Enum.map(focuses, &start_reviewer(source, scope, &1, kind, socket))
        {:ok, %{reviews: collect_reviews(started, timeout_s, socket)}}
      else
        Logger.info(
          "would start review agents scenario=:review_fanout caller=#{inspect(source.pane)}"
        )

        {:ok, %{dry_run: true}}
      end
    else
      {:error, "invalid review request"}
    end
  end

  defp start_reviewer(source, scope, focus, kind, socket) do
    name = "review-" <> focus

    instruction =
      "You are a code reviewer focused on #{focus}. Review the uncommitted changes shown by " <>
        "`git diff HEAD` in this directory. Do not modify files. End with a short list of findings."

    with {:ok, pane} <- create_execution_pane(source, socket),
         {:ok, _} <- start_agent(pane, name, kind, scope, socket, [instruction]) do
      {focus, {:ok, pane["pane_id"]}}
    else
      {:error, message} -> {focus, {:error, message}}
    end
  end

  defp collect_reviews(started, timeout_s, socket) do
    deadline = System.monotonic_time(:millisecond) + timeout_s * 1_000

    Enum.map(started, fn
      {focus, {:error, message}} ->
        %{focus: focus, status: "failed", detail: message}

      {focus, {:ok, pane}} ->
        # Let the agent leave its initial idle state, then wait for it to settle. If Herdr never
        # reports `working` (no detector for this agent), the result may predate its answer.
        observed? =
          match?(
            {:ok, _},
            Socket.request("agent.wait", %{target: pane, until: ["working"], timeout_ms: 20_000},
              server: socket,
              timeout: 22_000
            )
          )

        remaining = max(deadline - System.monotonic_time(:millisecond), 1_000)

        status =
          case Socket.request(
                 "agent.wait",
                 %{target: pane, until: ["idle", "done", "blocked"], timeout_ms: remaining},
                 server: socket,
                 timeout: remaining + 2_000
               ) do
            {:ok, _} -> if observed?, do: "finished", else: "idle_unobserved"
            {:error, %{code: "timeout"}} -> "timeout"
            _ -> "unconfirmed"
          end

        output =
          case Client.read_agent(pane, server: socket, lines: 120) do
            {:ok, %{"read" => %{"text" => text}}} when is_binary(text) ->
              String.slice(text, -2_000, 2_000)

            _ ->
              nil
          end

        %{focus: focus, pane_id: pane, status: status, output: output}
    end)
  end

  def run_command(caller, args, opts \\ []) do
    command = args[:command]
    wait_for = args[:wait_for]
    timeout_s = args[:timeout_s] || 30

    if valid_terminal_text?(command, 4_096) and
         (is_nil(wait_for) or valid_terminal_text?(wait_for, 256) or
            match?(
              {:regex, pattern} when is_binary(pattern) and byte_size(pattern) in 1..256,
              wait_for
            )) and
         is_integer(timeout_s) and timeout_s in 1..100 do
      execute(:run_command, caller, nil, opts, fn verified, socket ->
        progress = Keyword.get(opts, :progress, fn _, _ -> :ok end)
        progress.(0, "Creating command pane")

        with {:ok, pane} <- create_execution_pane(verified, socket),
             :ok <- send_command(pane, command, verified, socket) do
          progress.(1, "Command submitted")
          result = command_output(pane, wait_for, timeout_s, socket)
          progress.(2, "Command pane inspected")
          result
        end
      end)
    else
      {:error, "invalid command, output match, or timeout"}
    end
  end

  defp execute(scenario, caller, cwd, opts, operation) do
    live = live?(scenario)
    mode = if live, do: :live, else: :dry
    guard = Application.get_env(:jarvis2, :execution_guard, ExecutionGuard)
    socket = Keyword.get(opts, :server, Application.get_env(:jarvis2, :herdr_socket, Socket))

    case ExecutionGuard.reserve(caller, mode, guard) do
      {:ok, verified, lease} ->
        try do
          result =
            cond do
              not is_nil(cwd) and
                  (not is_binary(cwd) or Path.expand(cwd) != Path.expand(verified.cwd)) ->
                {:error, "cwd must be the caller's current directory"}

              live ->
                operation.(verified, socket)

              true ->
                Logger.info(
                  "would create a sibling pane scenario=#{inspect(scenario)} caller=#{inspect(verified.pane)}"
                )

                {:ok, %{dry_run: true}}
            end

          ExecutionGuard.finish(
            lease,
            if(match?({:ok, _}, result), do: :ok, else: :uncertain),
            guard
          )

          result
        rescue
          _ ->
            ExecutionGuard.finish(lease, :uncertain, guard)
            {:error, "execution may be partially complete; inspect the workspace before retrying"}
        catch
          :exit, _ ->
            ExecutionGuard.finish(lease, :uncertain, guard)
            {:error, "execution may be partially complete; inspect the workspace before retrying"}
        end

      error ->
        error
    end
  end

  defp create_execution_pane(caller, socket) do
    params = %{target_pane_id: caller.pane, direction: "right", cwd: caller.cwd, focus: false}
    result = Socket.request("pane.split", params, server: socket, timeout: 5_000)

    Logger.info(
      "Herdr live execution pane.split caller=#{inspect(caller.pane)} outcome=#{outcome(result)}"
    )

    case result do
      {:ok,
       %{"type" => "pane_info", "pane" => %{"pane_id" => id, "terminal_id" => terminal} = pane}}
      when is_binary(id) and byte_size(id) in 1..128 and is_binary(terminal) ->
        with :ok <- verify_execution_pane(caller, pane, socket),
             :ok <- await_shell(id, socket, System.monotonic_time(:millisecond) + 2_000),
             :ok <- verify_execution_pane(caller, pane, socket) do
          {:ok, pane}
        else
          {:error, reason} ->
            Logger.warning("Herdr execution preflight failed stage=#{inspect(reason)}")
            {:error, "created pane #{id} is not safely available; inspect it before retrying"}
        end

      {:ok, _} ->
        {:error, "pane may have been created; inspect the workspace before retrying"}

      {:error, %{code: code}} when code in ["timeout", "disconnected"] ->
        {:error, "pane may have been created; inspect the workspace before retrying"}

      {:error, _} ->
        {:error, "pane creation was rejected"}
    end
  end

  # A human-invoked action's source pane need not host an agent; it must still match the
  # fresh snapshot exactly.
  defp validate_source(%{human: true} = source, %{stale: false} = view) do
    verified =
      Jarvis2.MCP.Identity.resolve(
        %{"x-herdr-pane" => source.pane, "x-herdr-workspace" => source.workspace},
        view
      )

    if verified.pane == source.pane and verified.workspace == source.workspace and
         verified.tab == source.tab and verified.cwd == source.cwd and
         is_binary(source.cwd) and File.dir?(source.cwd),
       do: {:ok, verified},
       else: {:error, "source pane changed"}
  end

  defp validate_source(caller, view), do: ExecutionGuard.validate(caller, view)

  defp verify_execution_pane(caller, created, socket) do
    with {:ok, %{"snapshot" => %{"panes" => panes, "agents" => agents} = snapshot}}
         when is_list(panes) and is_list(agents) <-
           Client.snapshot(server: socket, timeout: 5_000) do
      case validate_source(caller, %{stale: false, snapshot: snapshot}) do
        {:ok, _} ->
          with [pane] <- Enum.filter(panes, &(&1["pane_id"] == created["pane_id"])),
               true <- pane["workspace_id"] == caller.workspace and pane["tab_id"] == caller.tab,
               true <-
                 created["workspace_id"] == caller.workspace and created["tab_id"] == caller.tab,
               true <-
                 pane["terminal_id"] == created["terminal_id"] and pane["pane_id"] != caller.pane,
               true <- Enum.all?(agents, &(&1["pane_id"] != pane["pane_id"])) do
            :ok
          else
            _ -> {:error, :unsafe_pane}
          end

        _ ->
          {:error, :unsafe_caller}
      end
    else
      _ -> {:error, :snapshot_unavailable}
    end
  end

  defp await_shell(pane, socket, deadline) do
    result = Socket.request("pane.process_info", %{pane_id: pane}, server: socket, timeout: 1_000)

    ready =
      case result do
        {:ok,
         %{
           "process_info" => %{
             "pane_id" => ^pane,
             "shell_pid" => pid,
             "foreground_process_group_id" => pid,
             "foreground_processes" => [%{"pid" => pid}]
           }
         }}
        when is_integer(pid) ->
          true

        _ ->
          false
      end

    cond do
      ready ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :shell_not_ready}

      true ->
        Process.sleep(100)
        await_shell(pane, socket, deadline)
    end
  end

  defp execution_scope(verified) do
    %{
      workspace: verified.workspace,
      tab: verified.tab,
      pane: verified.pane,
      statuses: ["idle", "done"],
      valid?: fn view -> match?({:ok, _}, ExecutionGuard.validate(verified, view)) end
    }
  end

  defp start_agent(pane, name, kind, scope, socket, args \\ []) do
    params = %{pane_id: pane["pane_id"], name: name, kind: kind, timeout_ms: 30_000}
    params = if args == [], do: params, else: Map.put(params, :args, args)
    result = Socket.request("agent.start", params, server: socket, timeout: 35_000)

    Logger.info("Herdr live agent.start caller=#{inspect(scope.pane)} outcome=#{outcome(result)}")

    case result do
      {:ok, %{"type" => "agent_started", "agent" => agent}} when is_map(agent) ->
        if agent["pane_id"] == pane["pane_id"] and agent["terminal_id"] == pane["terminal_id"] and
             agent["workspace_id"] == scope.workspace and agent["tab_id"] == scope.tab and
             agent["name"] == name and agent["agent"] in [nil, kind] do
          case await_started_agent(
                 pane,
                 name,
                 kind,
                 scope,
                 socket,
                 System.monotonic_time(:millisecond) + 30_000
               ) do
            :ok ->
              {:ok, agent}

            _ ->
              {:error,
               "agent may have started in pane #{pane["pane_id"]}; inspect it before retrying"}
          end
        else
          {:error,
           "agent may have started in pane #{pane["pane_id"]}; inspect it before retrying"}
        end

      {:error, %{code: code}} when code in ["timeout", "disconnected", "agent_not_ready"] ->
        {:error, "agent may have started in pane #{pane["pane_id"]}; inspect it before retrying"}

      _ ->
        {:error, "agent start failed in pane #{pane["pane_id"]}; inspect it before retrying"}
    end
  end

  defp await_started_agent(pane, name, kind, scope, socket, deadline) do
    ready =
      with {:ok, %{"snapshot" => %{"agents" => agents} = snapshot}} when is_list(agents) <-
             Client.snapshot(server: socket, timeout: 2_000),
           true <- scope.valid?.(%{stale: false, snapshot: snapshot}),
           [agent] <- Enum.filter(agents, &(&1["pane_id"] == pane["pane_id"])) do
        agent["terminal_id"] == pane["terminal_id"] and agent["workspace_id"] == scope.workspace and
          agent["tab_id"] == scope.tab and agent["name"] == name and agent["agent"] == kind and
          agent["agent_status"] in scope.statuses and agent["launch_pending"] != true and
          agent["interactive_ready"] != false
      else
        _ -> false
      end

    cond do
      ready ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :agent_not_ready}

      true ->
        Process.sleep(100)
        await_started_agent(pane, name, kind, scope, socket, deadline)
    end
  end

  defp maybe_prompt_new_agent(_caller, _pane, nil, _socket), do: "not_requested"

  defp maybe_prompt_new_agent(caller, pane, text, socket) do
    if live?(:agent_prompt) and await_new_agent(pane, System.monotonic_time(:millisecond) + 5_000) do
      case prompt(caller, pane["pane_id"], text, false, server: socket) do
        {:ok, _} ->
          "submitted"

        {:error, %{code: code}}
        when code in ["timeout", "disconnected", "agent_prompt_stalled"] ->
          "unconfirmed"

        _ ->
          "skipped"
      end
    else
      "skipped"
    end
  end

  defp await_new_agent(pane, deadline) do
    mirror = Application.get_env(:jarvis2, :mirror, Mirror)

    view =
      try do
        Mirror.get(mirror)
      catch
        :exit, _ -> nil
      end

    ready =
      case view do
        %{stale: false, snapshot: %{"agents" => agents}} when is_list(agents) ->
          Enum.any?(
            agents,
            &(&1["pane_id"] == pane["pane_id"] and &1["terminal_id"] == pane["terminal_id"] and
                &1["agent_status"] in ["idle", "done"])
          )

        _ ->
          false
      end

    cond do
      ready ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(100)
        await_new_agent(pane, deadline)
    end
  end

  defp send_command(pane, command, caller, socket) do
    result =
      Socket.request(
        "pane.send_input",
        %{pane_id: pane["pane_id"], text: command, keys: ["enter"]},
        server: socket,
        timeout: 5_000
      )

    Logger.info(
      "Herdr live pane.send_input caller=#{inspect(caller.pane)} outcome=#{outcome(result)}"
    )

    case result do
      {:ok, %{"type" => "ok"}} ->
        :ok

      {:ok, _} ->
        {:error,
         "command may have been submitted in pane #{pane["pane_id"]}; inspect it before retrying"}

      {:error, %{code: code}} when code in ["timeout", "disconnected"] ->
        {:error,
         "command may have been submitted in pane #{pane["pane_id"]}; inspect it before retrying"}

      _ ->
        {:error, "command was rejected in pane #{pane["pane_id"]}; inspect it before retrying"}
    end
  end

  defp command_output(pane, wait_for, timeout_s, socket) do
    id = pane["pane_id"]
    workspace = pane["workspace_id"]
    tab = pane["tab_id"]

    wait =
      if wait_for do
        params = %{
          pane_id: id,
          source: "recent_unwrapped",
          match: wait_match(wait_for),
          lines: 200,
          timeout_ms: timeout_s * 1_000
        }

        case Socket.request("pane.wait_for_output", params,
               server: socket,
               timeout: timeout_s * 1_000 + 2_000
             ) do
          {:ok, %{"type" => "output_matched", "pane_id" => ^id}} -> "matched"
          {:error, %{code: "timeout"}} -> "timeout"
          _ -> "unconfirmed"
        end
      else
        "not_requested"
      end

    case Socket.request(
           "pane.read",
           %{pane_id: id, source: "recent_unwrapped", lines: 200, format: "text"},
           server: socket,
           timeout: 5_000
         ) do
      {:ok,
       %{
         "type" => "pane_read",
         "read" =>
           %{"pane_id" => ^id, "workspace_id" => ^workspace, "tab_id" => ^tab, "text" => text} =
               read
       }}
      when is_binary(text) ->
        output = String.slice(text, -4_096, 4_096)

        {:ok,
         %{
           pane_id: id,
           wait: wait,
           output: output,
           truncated: read["truncated"] == true or byte_size(output) < byte_size(text)
         }}

      _ ->
        {:ok, %{pane_id: id, wait: wait, output: nil, read: "unavailable"}}
    end
  end

  # Internal callers may pass {:regex, pattern}; MCP input is always a plain substring.
  defp wait_match({:regex, pattern}), do: %{type: "regex", value: pattern}
  defp wait_match(text), do: %{type: "substring", value: text}

  defp valid_cwd?(nil, _caller), do: true

  defp valid_cwd?(cwd, caller) when is_binary(cwd) and is_map(caller) do
    is_binary(caller[:cwd]) and Path.expand(cwd) == Path.expand(caller[:cwd])
  end

  defp valid_cwd?(_, _), do: false

  defp valid_terminal_text?(text, limit) do
    is_binary(text) and byte_size(text) in 1..limit and String.valid?(text) and
      not Enum.any?(String.to_charlist(text), &(&1 in 0..31 or &1 in 127..159))
  end

  defp live?(scenario),
    do:
      Application.get_env(:jarvis2, :live, false) and
        scenario in Application.get_env(:jarvis2, :live_scenarios, [])

  defp valid_prompt?(target, text, wait) do
    is_binary(target) and byte_size(target) in 1..128 and is_binary(text) and
      byte_size(text) in 1..8_192 and String.valid?(text) and is_boolean(wait) and
      not Enum.any?(String.to_charlist(text), &(&1 in 0..8 or &1 in 11..31 or &1 in 127..159))
  end

  defp outcome({:ok, _}), do: "ok"
  defp outcome({:error, _}), do: "error"
end
