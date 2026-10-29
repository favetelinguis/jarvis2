defmodule Jarvis2.Runs.Launcher do
  @moduledoc """
  Performs the Herdr side of a run: split a pane next to an anchor pane, start the agent in it and
  deliver the task. The UI acts as the named system caller `ui`, so the execution and prompt guards
  and the live/dry-run gates apply exactly as they do for MCP callers.
  """
  require Logger

  alias Jarvis2.Fleet
  alias Jarvis2.Herdr.{Actions, ExecutionGuard, Mirror, Socket}
  alias Jarvis2.Runs.Run

  @ui %{system: "ui", pane: "system:ui"}
  @prompt_wait_ms 15_000
  @retryable ~w(target_unavailable target_not_ready caller_or_mirror_unavailable)

  def caller(%Run{id: id}), do: Map.put(@ui, :run_id, id)

  @doc "`:live` only when live mode and both the spawn and prompt scenarios are enabled."
  def mode, do: if(scenario?(:agent_spawn) and scenario?(:agent_prompt), do: :live, else: :dry)

  @doc "Whether a run could be started now; the error is shown to the user."
  def availability(view) do
    case mode() do
      :dry ->
        :ok

      :live ->
        with {:ok, _} <- fresh(view), {:ok, _} <- anchor(view), do: :ok
    end
  end

  @doc "The Herdr calls a start would make, without making them."
  def plan(%Run{} = run, anchor_pane_id) do
    [
      %{
        method: "pane.split",
        params: %{
          target_pane_id: anchor_pane_id,
          direction: "right",
          cwd: run.cwd,
          env_keys: Map.keys(env(run))
        }
      },
      %{
        method: "agent.start",
        params: %{name: agent_name(run), kind: run.kind, args: agent_args(run)}
      },
      %{method: "agent.prompt", params: %{target: "<new pane>", text_bytes: byte_size(run.task)}}
    ]
  end

  def agent_name(%Run{id: id}), do: "run-" <> String.slice(id, 0, 8)

  @doc "Pi-specific arguments; other agent kinds start with their own defaults."
  def agent_args(%Run{kind: "pi", model: model, thinking: thinking}) do
    [provider, model_id] = String.split(model, "/", parts: 2)
    ["--provider", provider, "--model", model_id, "--thinking", thinking]
  end

  def agent_args(_run), do: []

  @doc "Starts the run's agent. Returns the details to store on the run."
  def start(%Run{} = run) do
    mode = mode()

    guard = Application.get_env(:jarvis2, :execution_guard, ExecutionGuard)

    case ExecutionGuard.reserve(caller(run), mode, guard) do
      {:ok, _verified, lease} ->
        result = guarded(fn -> execute(run, mode) end)

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

  @doc "Closes the run's pane, but only if it is still the terminal that was created for it."
  def close(%Run{pane_id: nil}), do: {:ok, :dry_run}

  def close(%Run{} = run) do
    with {:ok, view} <- fresh(current_view()) do
      case find(run, view) do
        nil -> {:ok, :gone}
        {pane, _agent} -> close_pane(pane["pane_id"])
      end
    end
  end

  defp close_pane(pane_id) do
    case Actions.call(:agent_spawn, "pane.close", %{pane_id: pane_id},
           caller: "ui",
           server: socket()
         ) do
      {:ok, %{dry_run: true}} -> {:ok, :dry_run}
      {:ok, _} -> {:ok, :closed}
      {:error, _} -> {:error, "Herdr could not close the pane"}
    end
  end

  @doc "Brings the run's agent to the front in Herdr (live mode only)."
  def focus(%Run{pane_id: pane_id} = run) when is_binary(pane_id) do
    with {:ok, view} <- fresh(current_view()),
         {_pane, _agent} <- find(run, view) || {:error, "The run's pane is gone."} do
      case Actions.call(:agent_spawn, "agent.focus", %{target: pane_id},
             caller: "ui",
             server: socket()
           ) do
        {:ok, %{dry_run: true}} -> {:ok, :dry_run}
        {:ok, _} -> {:ok, :focused}
        {:error, _} -> {:error, "Herdr could not focus the pane."}
      end
    end
  end

  def focus(_run), do: {:error, "The run has no pane."}

  @doc "Sends a prompt to the run's agent through the prompt guard."
  def prompt(%Run{pane_id: pane_id} = run, text) when is_binary(pane_id) do
    with {:ok, view} <- fresh(current_view()),
         {_pane, _agent} <- find(run, view) || {:error, "The run's pane is gone."} do
      caller = caller(run)

      caller
      |> Actions.prompt(pane_id, text, false, server: socket())
      |> Fleet.audit("fleet.prompt", caller, %{target: pane_id, text: text}, source: :ui)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, %{code: code}} -> {:error, prompt_error(code)}
      end
    else
      {:error, message} -> {:error, message}
    end
  end

  def prompt(_run, _text), do: {:error, "The run has no pane."}

  @doc "The pane and agent of a run in a mirror view, if the pane is still the one we created."
  def find(%Run{pane_id: pane_id, terminal_id: terminal}, %{snapshot: %{"panes" => panes} = snap})
      when is_binary(pane_id) do
    case Enum.find(panes, &(&1["pane_id"] == pane_id and &1["terminal_id"] == terminal)) do
      nil -> nil
      pane -> {pane, Enum.find(snap["agents"] || [], &(&1["pane_id"] == pane_id))}
    end
  end

  def find(_run, _view), do: nil

  defp execute(run, :dry) do
    anchor =
      case anchor(current_view()) do
        {:ok, pane} -> pane["pane_id"]
        _ -> nil
      end

    {:ok, %{mode: :dry, plan: plan(run, anchor)}}
  end

  defp execute(run, :live) do
    with {:ok, view} <- fresh(current_view()),
         {:ok, anchor} <- anchor(view),
         {:ok, pane} <- split(run, anchor),
         :ok <- shell_ready(pane),
         {:ok, _agent} <- start_agent(run, pane) do
      {:ok,
       %{
         mode: :live,
         pane_id: pane["pane_id"],
         terminal_id: pane["terminal_id"],
         agent_name: agent_name(run),
         prompt: send_task(run, pane["pane_id"])
       }}
    end
  end

  defp split(run, anchor) do
    params = %{
      target_pane_id: anchor["pane_id"],
      direction: "right",
      cwd: run.cwd,
      focus: false,
      env: env(run)
    }

    result = Socket.request("pane.split", params, server: socket(), timeout: 5_000)
    Logger.info("Herdr live run pane.split outcome=#{outcome(result)}")

    case result do
      {:ok, %{"type" => "pane_info", "pane" => %{"pane_id" => id, "terminal_id" => t} = pane}}
      when is_binary(id) and is_binary(t) ->
        {:ok, pane}

      {:error, %{code: code}} when code not in ["timeout", "disconnected"] ->
        {:error, "Herdr rejected the new pane (#{code})."}

      _ ->
        {:error, "A pane may have been created; inspect the workspace before retrying."}
    end
  end

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
  defp send_task(run, pane_id) do
    caller = caller(run)
    deadline = System.monotonic_time(:millisecond) + @prompt_wait_ms
    text = Jarvis2.Runs.Prompt.build(run)

    result = prompt_when_ready(caller, pane_id, text, deadline)
    Fleet.audit(result, "fleet.prompt", caller, %{target: pane_id, text: text}, source: :ui)
    if match?({:ok, _}, result), do: "submitted", else: "unconfirmed"
  end

  defp prompt_when_ready(caller, pane_id, text, deadline) do
    result = Actions.prompt(caller, pane_id, text, false, server: socket())

    with {:error, %{code: code}} when code in @retryable <- result,
         true <- System.monotonic_time(:millisecond) < deadline do
      Mirror.invalidate(mirror())
      Process.sleep(250)
      prompt_when_ready(caller, pane_id, text, deadline)
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

  @doc false
  def anchor(%{snapshot: %{"panes" => panes} = snapshot}) when is_list(panes) do
    candidates = [Application.get_env(:jarvis2, :anchor_pane), snapshot["focused_pane_id"]]

    Enum.find_value(
      candidates,
      {:error, "No pane to split from: run Jarvis2 inside Herdr or focus a pane."},
      fn id ->
        pane = id && Enum.find(panes, &(&1["pane_id"] == id))
        pane && {:ok, pane}
      end
    )
  end

  def anchor(_view), do: {:error, "Herdr is not connected."}

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
  defp prompt_error(code), do: "The prompt was not sent (#{code})."

  defp current_view do
    Mirror.get(mirror())
  catch
    :exit, _ -> nil
  end

  defp scenario?(name),
    do:
      Application.get_env(:jarvis2, :live, false) and
        name in Application.get_env(:jarvis2, :live_scenarios, [])

  defp mirror, do: Application.get_env(:jarvis2, :mirror, Mirror)
  defp socket, do: Application.get_env(:jarvis2, :herdr_socket, Socket)
  defp outcome({:ok, _}), do: "ok"
  defp outcome({:error, _}), do: "error"
end
