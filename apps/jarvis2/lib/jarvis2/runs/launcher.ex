defmodule Jarvis2.Runs.Launcher do
  @moduledoc """
  Performs the Herdr side of a run: create a tab in the checkout workspace, start the agent in it and
  deliver the task. The UI acts as the named system caller `ui` through the execution and prompt guards.
  """
  require Logger

  alias Jarvis2.Fleet
  alias Jarvis2.Herdr.{Actions, ExecutionGuard, Mirror, Socket, Workspaces}
  alias Jarvis2.Runs.Run

  @pi_extension "/home/favetelinguis/repos/jarvis2/.pi/jarvis2-run.js"
  @ui %{system: "ui", pane: "system:ui"}
  @prompt_wait_ms 15_000
  @retryable ~w(target_unavailable target_not_ready caller_or_mirror_unavailable target_busy rate_limited)

  def caller(%Run{id: id}), do: Map.put(@ui, :run_id, id)

  @doc "Whether a run could be started now; the error is shown to the user."
  def availability(view), do: with({:ok, _} <- fresh(view), do: :ok)

  def agent_name(%Run{id: id}), do: "run-" <> String.slice(id, 0, 8)

  @doc "Pi-specific arguments; other agent kinds start with their own defaults."
  def agent_args(%Run{kind: "pi", model: model, thinking: thinking, session_id: session_id}) do
    [provider, model_id] = String.split(model, "/", parts: 2)

    [
      "--provider",
      provider,
      "--model",
      model_id,
      "--thinking",
      thinking,
      "--extension",
      @pi_extension,
      "--skill",
      Path.join([:code.priv_dir(:jarvis2), "skills", "jarvis2-slide-deck"])
    ] ++ if(session_id, do: ["--session-id", session_id], else: [])
  end

  def agent_args(_run), do: []

  @doc "Starts the run's agent. Returns the details to store on the run."
  def start(%Run{} = run, label \\ nil, placement \\ :tab) do
    guard = Application.get_env(:jarvis2, :execution_guard, ExecutionGuard)

    if Actions.valid_prompt_text?(Jarvis2.Runs.Prompt.build(run)) do
      reserve_and_start(run, label, placement, guard)
    else
      {:error, "The complete run prompt is invalid or exceeds 65536 bytes."}
    end
  end

  defp reserve_and_start(run, label, placement, guard) do
    case ExecutionGuard.reserve(caller(run), guard) do
      {:ok, _verified, lease} ->
        result = guarded(fn -> execute(run, label, placement) end)

        ExecutionGuard.finish(
          lease,
          if(match?({:ok, _}, result), do: :ok, else: :uncertain),
          guard
        )

        result

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Closes the owned tab, or the original pane for legacy runs."
  def close(%Run{tab_id: tab_id}) when is_binary(tab_id) and tab_id != "" do
    case fresh(current_view()) do
      {:ok, %{snapshot: %{"tabs" => tabs}}} when is_list(tabs) ->
        if Enum.any?(tabs, &(&1["tab_id"] == tab_id)), do: close_tab(tab_id), else: {:ok, :gone}

      {:error, message} ->
        {:error, message}

      _ ->
        {:error, "Herdr could not verify the tab"}
    end
  end

  def close(%Run{pane_id: nil}), do: {:ok, :gone}

  def close(%Run{} = run) do
    with {:ok, view} <- fresh(current_view()) do
      case find(run, view) do
        nil -> {:ok, :gone}
        {pane, _agent} -> close_pane(pane["pane_id"])
      end
    end
  end

  defp close_tab(tab_id) do
    case Socket.request("tab.close", %{tab_id: tab_id}, server: socket()) do
      {:ok, _} -> {:ok, :closed}
      {:error, _} -> {:error, "Herdr could not close the tab"}
    end
  end

  defp close_pane(pane_id) do
    case Socket.request("pane.close", %{pane_id: pane_id}, server: socket()) do
      {:ok, _} -> {:ok, :closed}
      {:error, _} -> {:error, "Herdr could not close the pane"}
    end
  end

  @doc "Sends a prompt to the run's agent through the prompt guard."
  def prompt(run, text, opts \\ [])

  def prompt(%Run{pane_id: pane_id} = run, text, opts) when is_binary(pane_id) do
    with {:ok, view} <- fresh(current_view()),
         {_pane, _agent} <- find(run, view) || {:error, "The run's pane is gone."} do
      caller = caller(run)

      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :wait_ms, 0)
      valid = Keyword.get(opts, :valid, fn -> true end)
      check = fn -> check_prompt_target(run, valid) end

      caller
      |> prompt_when_ready(pane_id, text, deadline, check)
      |> Fleet.audit("fleet.prompt", caller, %{target: pane_id, text: text}, source: :ui)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, %{code: code}} -> {:error, prompt_error(code)}
      end
    else
      {:error, message} -> {:error, message}
    end
  end

  def prompt(_run, _text, _opts), do: {:error, "The run has no pane."}

  @doc "The pane and agent of a run in a mirror view, if the pane is still the one we created."
  def find(%Run{pane_id: pane_id, terminal_id: terminal}, %{snapshot: %{"panes" => panes} = snap})
      when is_binary(pane_id) do
    case Enum.find(panes, &(&1["pane_id"] == pane_id and &1["terminal_id"] == terminal)) do
      nil -> nil
      pane -> {pane, Enum.find(snap["agents"] || [], &(&1["pane_id"] == pane_id))}
    end
  end

  def find(_run, _view), do: nil

  defp execute(run, label, placement) do
    with {:ok, view} <- fresh(current_view()),
         {:ok, workspace} <- Workspaces.resolve(run.cwd, run.worktree),
         run = %{run | cwd: workspace.checkout_path},
         {:ok, pane, tab_id} <- create_pane(run, view, workspace.workspace_id, label, placement),
         :ok <- rename_role(pane, run.role),
         :ok <- close_fresh_tabs(workspace.fresh_tab_ids),
         :ok <- shell_ready(pane),
         {:ok, _agent} <- start_agent(run, pane) do
      display_role(pane, run)

      {:ok,
       %{
         tab_id: tab_id,
         workspace_id: workspace.workspace_id,
         cwd: workspace.checkout_path,
         pane_id: pane["pane_id"],
         terminal_id: pane["terminal_id"],
         agent_name: agent_name(run),
         prompt: send_task(run, pane)
       }}
    end
  end

  defp rename_role(_pane, nil), do: :ok

  defp rename_role(pane, role) do
    result =
      Socket.request("pane.rename", %{pane_id: pane["pane_id"], label: role}, server: socket())

    Logger.info("Herdr live run pane.rename outcome=#{outcome(result)}")
    if match?({:error, _}, result), do: Logger.warning("Could not label run pane")
    :ok
  end

  defp display_role(_pane, %Run{role: nil}), do: :ok

  defp display_role(pane, %Run{role: role, kind: kind}) do
    result =
      Socket.request(
        "pane.report_metadata",
        %{
          pane_id: pane["pane_id"],
          source: "custom:jarvis2-role",
          agent: kind,
          display_agent: role
        },
        server: socket()
      )

    Logger.info("Herdr live run pane.report_metadata outcome=#{outcome(result)}")
    if match?({:error, _}, result), do: Logger.warning("Could not set run role display name")
    :ok
  end

  defp close_fresh_tabs(tabs) do
    Enum.each(tabs, fn tab ->
      case close_tab(tab) do
        {:ok, _} -> :ok
        {:error, _} -> Logger.warning("Could not close a fresh workspace tab")
      end
    end)

    :ok
  end

  defp create_pane(run, _view, workspace_id, label, :tab),
    do: create_tab(run, workspace_id, label)

  defp create_pane(run, view, workspace_id, label, {:split, pane_id, tab_id}) do
    panes = view.snapshot["panes"] || []

    if Enum.any?(
         panes,
         &(&1["pane_id"] == pane_id and &1["tab_id"] == tab_id and
             &1["workspace_id"] == workspace_id)
       ) do
      split_pane(run, pane_id, tab_id)
    else
      create_pane(run, view, workspace_id, label, :tab)
    end
  end

  defp split_pane(run, pane_id, tab_id) do
    params = %{
      target_pane_id: pane_id,
      direction: "right",
      cwd: run.cwd,
      focus: false,
      env: env(run)
    }

    result = Socket.request("pane.split", params, server: socket(), timeout: 5_000)
    Logger.info("Herdr live run pane.split outcome=#{outcome(result)}")

    case result do
      {:ok,
       %{
         "type" => "pane_info",
         "pane" => %{"pane_id" => id, "terminal_id" => terminal, "tab_id" => ^tab_id} = pane
       }}
      when is_binary(id) and id != "" and is_binary(terminal) and terminal != "" ->
        {:ok, pane, tab_id}

      {:error, %{code: code}} when code not in ["timeout", "disconnected"] ->
        {:error, "Herdr rejected the new pane (#{code})."}

      _ ->
        {:error, "A pane may have been created; inspect the workspace before retrying."}
    end
  end

  defp create_tab(run, workspace_id, label) do
    params = %{
      workspace_id: workspace_id,
      label: String.slice(label || String.replace(run.task, ~r/\s+/, " "), 0, 32),
      cwd: run.cwd,
      focus: false,
      env: env(run)
    }

    result = Socket.request("tab.create", params, server: socket(), timeout: 5_000)
    Logger.info("Herdr live run tab.create outcome=#{outcome(result)}")

    case result do
      {:ok,
       %{"type" => "tab_created", "root_pane" => %{"pane_id" => id, "terminal_id" => t} = pane} =
           reply}
      when is_binary(id) and id != "" and is_binary(t) and t != "" ->
        {:ok, pane, tab_id(reply)}

      {:error, %{code: code}} when code not in ["timeout", "disconnected"] ->
        {:error, "Herdr rejected the new tab (#{code})."}

      _ ->
        {:error, "A tab may have been created; inspect the workspace before retrying."}
    end
  end

  defp tab_id(%{"tab" => %{"tab_id" => id}}) when is_binary(id) and id != "", do: id
  defp tab_id(_), do: nil

  defp shell_ready(pane) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    case Actions.await_shell(pane["pane_id"], socket(), deadline) do
      :ok -> :ok
      _ -> {:error, "Pane #{pane["pane_id"]} did not reach a shell prompt; inspect it."}
    end
  end

  defp start_agent(run, pane) do
    id = pane["pane_id"]
    name = agent_name(run)

    params = %{
      pane_id: id,
      name: name,
      kind: run.kind,
      args: agent_args(run),
      timeout_ms: 30_000
    }

    result = Socket.request("agent.start", params, server: socket(), timeout: 35_000)
    Logger.info("Herdr live run agent.start outcome=#{outcome(result)}")

    case result do
      {:ok, %{"type" => "agent_started", "agent" => %{"pane_id" => ^id} = agent}} ->
        {:ok, agent}

      _ ->
        {:error, "The agent may not have started in pane #{id}; inspect it before retrying."}
    end
  end

  # The mirror learns about the new agent asynchronously, so keep nudging it until the prompt guard
  # sees an idle, ready target.
  defp send_task(run, pane) do
    caller = caller(run)
    pane_id = pane["pane_id"]
    expected = %{run | pane_id: pane_id, terminal_id: pane["terminal_id"]}
    deadline = System.monotonic_time(:millisecond) + @prompt_wait_ms
    text = Jarvis2.Runs.Prompt.build(run)
    check = fn -> check_prompt_target(expected, fn -> true end) end

    result = prompt_when_ready(caller, pane_id, text, deadline, check)
    Fleet.audit(result, "fleet.prompt", caller, %{target: pane_id, text: text}, source: :ui)
    if match?({:ok, _}, result), do: "submitted", else: "unconfirmed"
  end

  defp check_prompt_target(run, valid) do
    with true <- valid.(),
         {:ok, %{snapshot: %{"panes" => panes}}} when is_list(panes) <- fresh(current_view()) do
      case Enum.find(panes, &(&1["pane_id"] == run.pane_id)) do
        nil -> {:error, %{code: "target_unavailable"}}
        %{"terminal_id" => terminal} when terminal == run.terminal_id -> :ok
        _ -> {:error, %{code: "target_changed"}}
      end
    else
      false -> {:error, %{code: "delivery_cancelled"}}
      _ -> {:error, %{code: "caller_or_mirror_unavailable"}}
    end
  end

  defp prompt_when_ready(caller, pane_id, text, deadline, check) do
    result =
      case check.() do
        :ok -> Actions.prompt(caller, pane_id, text, false, server: socket())
        error -> error
      end

    with {:error, %{code: code}} when code in @retryable <- result,
         true <- System.monotonic_time(:millisecond) < deadline do
      Mirror.invalidate(mirror())
      Process.sleep(250)
      prompt_when_ready(caller, pane_id, text, deadline, check)
    else
      _ -> result
    end
  end

  defp guarded(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("run launch crashed: #{inspect(error.__struct__)}")
      {:error, "The launch crashed; inspect the workspace before retrying."}
  catch
    :exit, _ -> {:error, "Herdr became unavailable during the launch; inspect the workspace."}
  end

  defp fresh(%{stale: false, snapshot: snapshot} = view) when is_map(snapshot), do: {:ok, view}
  defp fresh(_), do: {:error, "Herdr is not connected or its state is stale."}

  defp env(run) do
    %{"JARVIS2_RUN_ID" => run.id, "JARVIS2_MCP_URL" => mcp_url()}
  end

  defp mcp_url do
    port = get_in(Application.get_env(:jarvis2, Jarvis2Web.Endpoint, []), [:http, :port]) || 4747
    "http://127.0.0.1:#{port}/mcp"
  end

  defp prompt_error(code) when code in ["target_not_ready", "target_unavailable"],
    do: "The agent is busy or not ready; wait until it is idle."

  defp prompt_error("rate_limited"), do: "Too many prompts; try again in a minute."
  defp prompt_error("target_busy"), do: "A prompt was just sent; try again in a few seconds."
  defp prompt_error("target_changed"), do: "The run's pane was replaced; the prompt was not sent."

  defp prompt_error(code) when code in ["timeout", "disconnected", "agent_prompt_stalled"],
    do: "The prompt may have been submitted; inspect the agent before retrying (#{code})."

  defp prompt_error(code), do: "The prompt was not sent (#{code})."

  defp current_view do
    Mirror.get(mirror())
  catch
    :exit, _ -> nil
  end

  defp mirror, do: Application.get_env(:jarvis2, :mirror, Mirror)
  defp socket, do: Application.get_env(:jarvis2, :herdr_socket, Socket)
  defp outcome({:ok, _}), do: "ok"
  defp outcome({:error, _}), do: "error"
end
