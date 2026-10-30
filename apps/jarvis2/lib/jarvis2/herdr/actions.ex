defmodule Jarvis2.Herdr.Actions do
  @moduledoc "Single entry point for scenario-gated Herdr mutations."
  require Logger
  alias Jarvis2.Herdr.{Client, ExecutionGuard, Mirror, PromptGuard, Socket}

  # Agent-facing execution cannot bypass its dedicated policy through call/4.
  @guarded_methods ~w(agent.prompt agent.start agent.send_keys pane.run pane.send_input pane.send_text pane.send_keys)

  def call(scenario, method, params, opts \\ [])
      when is_atom(scenario) and is_binary(method) and is_map(params) do
    caller = Keyword.get(opts, :caller, "unknown")

    if enabled?(scenario) do
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
      disabled()
    end
  end

  def prompt(caller, target, text, wait, opts \\ []) do
    guard = Application.get_env(:jarvis2, :prompt_guard, PromptGuard)

    cond do
      not valid_prompt?(target, text, wait) ->
        {:error, %{code: "invalid_prompt"}}

      not enabled?(:agent_prompt) and not run_launcher?(caller) ->
        disabled()

      true ->
        case PromptGuard.reserve(caller, target, guard) do
          {:ok, pane, lease} ->
            params =
              if wait,
                do: %{target: pane, text: text, wait: %{timeout_ms: 60_000}},
                else: %{target: pane, text: text}

            result =
              try do
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
    end
  end

  defp run_launcher?(%{system: system, run_id: id})
       when system in ["ui", "subagent"] and is_binary(id),
       do: true

  defp run_launcher?(_), do: false

  @agent_kinds ~w(pi claude codex gemini cursor devin agy cline omp mastracode opencode copilot kimi kiro droid amp grok hermes kilo qodercli qwen letta maki muse)

  def agent_kinds, do: @agent_kinds

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
    guard = Application.get_env(:jarvis2, :execution_guard, ExecutionGuard)
    socket = Keyword.get(opts, :server, Application.get_env(:jarvis2, :herdr_socket, Socket))

    if enabled?(scenario) do
      execute_guarded(caller, cwd, guard, socket, operation)
    else
      disabled()
    end
  end

  defp execute_guarded(caller, cwd, guard, socket, operation) do
    case ExecutionGuard.reserve(caller, guard) do
      {:ok, verified, lease} ->
        try do
          result =
            if not is_nil(cwd) and
                 (not is_binary(cwd) or Path.expand(cwd) != Path.expand(verified.cwd)) do
              {:error, "cwd must be the caller's current directory"}
            else
              operation.(verified, socket)
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

  defp validate_source(caller, view), do: ExecutionGuard.validate(caller, view)

  defp verify_execution_pane(caller, created, socket) do
    case Client.snapshot(server: socket, timeout: 5_000) do
      {:ok, %{"snapshot" => %{"panes" => panes, "agents" => agents} = snapshot}}
      when is_list(panes) and is_list(agents) ->
        case validate_source(caller, %{stale: false, snapshot: snapshot}) do
          {:ok, _} -> verify_created_pane(caller, created, panes, agents)
          _ -> {:error, :unsafe_caller}
        end

      _ ->
        {:error, :snapshot_unavailable}
    end
  end

  defp verify_created_pane(caller, created, panes, agents) do
    with [pane] <- Enum.filter(panes, &(&1["pane_id"] == created["pane_id"])),
         true <- pane["workspace_id"] == caller.workspace and pane["tab_id"] == caller.tab,
         true <- created["workspace_id"] == caller.workspace and created["tab_id"] == caller.tab,
         true <- pane["terminal_id"] == created["terminal_id"] and pane["pane_id"] != caller.pane,
         true <- Enum.all?(agents, &(&1["pane_id"] != pane["pane_id"])) do
      :ok
    else
      _ -> {:error, :unsafe_pane}
    end
  end

  @doc false
  def await_shell(pane, socket, deadline) do
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

  defp start_agent(pane, name, kind, scope, socket) do
    params = %{pane_id: pane["pane_id"], name: name, kind: kind, timeout_ms: 30_000}
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
    if enabled?(:agent_prompt) and
         await_new_agent(pane, System.monotonic_time(:millisecond) + 5_000) do
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

  defp enabled?(scenario), do: scenario in Application.get_env(:jarvis2, :live_scenarios, [])
  defp disabled, do: {:error, %{code: "disabled", message: "scenario is disabled"}}

  @prompt_limit 65_536
  def prompt_limit, do: @prompt_limit

  def valid_prompt_text?(text) do
    is_binary(text) and byte_size(text) in 1..@prompt_limit and valid_prompt_characters?(text)
  end

  def valid_prompt_characters?(text) do
    is_binary(text) and String.valid?(text) and
      not Enum.any?(String.to_charlist(text), &(&1 in 0..8 or &1 in 11..31 or &1 in 127..159))
  end

  defp valid_prompt?(target, text, wait) do
    is_binary(target) and byte_size(target) in 1..128 and is_boolean(wait) and
      valid_prompt_text?(text)
  end

  defp outcome({:ok, _}), do: "ok"
  defp outcome({:error, _}), do: "error"
end
