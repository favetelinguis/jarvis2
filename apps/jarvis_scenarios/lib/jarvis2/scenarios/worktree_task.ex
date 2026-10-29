defmodule Jarvis2.Scenarios.WorktreeTask do
  @moduledoc """
  Worktree-per-task (U10) and GitHub issue intake (U12).

  A human action creates a linked worktree workspace and starts an agent in it. The
  agent's first prompt is a launch argument, so the flow never prompts an agent that is
  already running.
  """
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Mirror}
  alias Jarvis2.MCP.{Identity, Picker}

  @issue_url ~r"\Ahttps://github\.com/[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}/(issues|pull)/([0-9]{1,9})\z"
  @window_ms 60_000
  @max_per_window 4
  @cooldown_ms 60_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Parses a GitHub issue or pull-request URL into a task slug and initial prompt."
  def parse_issue(url) when is_binary(url) and byte_size(url) <= 512 do
    case Regex.run(@issue_url, url) do
      [_, kind, number] ->
        prefix = if kind == "issues", do: "issue", else: "pr"
        {:ok, %{slug: "#{prefix}-#{number}", prompt: "Work on " <> url}}

      _ ->
        :error
    end
  end

  def parse_issue(_), do: :error

  @doc "Turns a typed task name into a branch-safe slug."
  def slugify(text) when is_binary(text) do
    slug =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    if slug == "", do: :error, else: {:ok, slug}
  end

  def slugify(_), do: :error

  @impl true
  def init(_) do
    Jarvis2.Bus.subscribe("hook:action")
    {:ok, %{active: %{}, rates: %{}, cooldowns: %{}}}
  end

  @impl true
  def handle_info({:jarvis2, "hook:action", %{id: id, body: body}}, state)
      when id in ["new-task", "issue-link"] and is_map(body) do
    context = if is_map(body["context"]), do: body["context"], else: %{}

    source =
      Identity.resolve(%{
        "x-herdr-pane" => context["focused_pane_id"],
        "x-herdr-workspace" => context["workspace_id"]
      })

    now = System.monotonic_time(:millisecond)
    state = prune(state, now)
    issue = if id == "issue-link", do: parse_issue(body["clicked_url"]), else: nil

    cond do
      source.pane == "unknown" ->
        Logger.warning("Herdr #{id} requires a fresh known pane")
        {:noreply, state}

      id == "issue-link" and issue == :error ->
        Logger.warning("Herdr issue-link rejected an unsupported URL")
        {:noreply, state}

      not live?(id) ->
        Logger.info(
          "would create a worktree task action=#{inspect(id)} caller=#{inspect(source.pane)}"
        )

        {:noreply, state}

      Map.has_key?(state.active, source.workspace) or
        Map.has_key?(state.cooldowns, source.workspace) or
          length(Map.get(state.rates, source.workspace, [])) >= @max_per_window ->
        Logger.warning("Herdr #{id} is busy, cooling down, or rate limited for this workspace")
        {:noreply, state}

      true ->
        start(id, source, issue, state, now)
    end
  end

  def handle_info({:finished, workspace, outcome}, state) do
    Logger.info("Herdr worktree task workspace=#{inspect(workspace)} outcome=#{outcome}")
    Jarvis2.Bus.publish("scenario:worktree_task", %{workspace: workspace, outcome: outcome})
    state = release(state, workspace)

    # Even a rejected request may have partly succeeded; do not retry quickly.
    cooldowns =
      if outcome == :ok,
        do: state.cooldowns,
        else:
          Map.put(state.cooldowns, workspace, System.monotonic_time(:millisecond) + @cooldown_ms)

    {:noreply, %{state | cooldowns: cooldowns}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    workspace =
      Enum.find_value(state.active, fn {workspace, {_pid, monitor}} ->
        if ref == monitor, do: workspace
      end)

    if workspace, do: {:noreply, release(state, workspace)}, else: {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start(id, source, issue, state, now) do
    parent = self()

    case Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn ->
           outcome =
             try do
               run(id, source, issue)
             rescue
               _ -> :error
             catch
               :exit, _ -> :error
             end

           send(parent, {:finished, source.workspace, outcome})
         end) do
      {:ok, pid} ->
        state = put_in(state.active[source.workspace], {pid, Process.monitor(pid)})
        {:noreply, update_in(state.rates[source.workspace], &[now | &1 || []])}

      {:error, _} ->
        Logger.warning("Herdr #{id} could not start")
        {:noreply, state}
    end
  end

  defp run("issue-link", source, {:ok, %{slug: slug, prompt: prompt}}),
    do: launch(source, slug, prompt)

  defp run("new-task", source, _) do
    with {:ok, %{answer: name}} when is_binary(name) <-
           Picker.ask("New task name:", [], 60, source, agent: false),
         {:ok, slug} <- slugify(name),
         {:ok, %{answer: text}} when is_binary(text) <-
           Picker.ask("Prompt for the agent (may be empty):", [], 60, source, agent: false) do
      launch(source, slug, if(text == "", do: nil, else: "Task: " <> text))
    else
      _ -> :cancelled_or_failed
    end
  end

  defp launch(source, slug, prompt) do
    kind = Application.get_env(:jarvis2, :task_agent_kind, "pi")
    mirror = Application.get_env(:jarvis2, :mirror, Mirror)

    # Re-resolve right before acting; the picker may have taken a while.
    fresh =
      Identity.resolve(
        %{"x-herdr-pane" => source.pane, "x-herdr-workspace" => source.workspace},
        Mirror.get(mirror)
      )

    if fresh.pane == source.pane and fresh.workspace == source.workspace do
      case Actions.create_task(source, %{slug: slug, kind: kind, prompt: prompt}) do
        {:ok, _} ->
          :ok

        {:error, message} ->
          Logger.warning("Herdr worktree task failed: #{message}")
          :error
      end
    else
      :cancelled_or_failed
    end
  end

  defp live?("new-task"), do: live_all?([:human_picker, :worktree_task, :agent_spawn])
  defp live?(_), do: live_all?([:worktree_task, :agent_spawn])

  defp live_all?(required) do
    scenarios = Application.get_env(:jarvis2, :live_scenarios, [])
    Application.get_env(:jarvis2, :live, false) and Enum.all?(required, &(&1 in scenarios))
  end

  defp prune(state, now) do
    rates =
      state.rates
      |> Map.new(fn {key, times} -> {key, Enum.filter(times, &(now - &1 < @window_ms))} end)
      |> Map.reject(fn {_, times} -> times == [] end)

    %{
      state
      | rates: rates,
        cooldowns: Map.filter(state.cooldowns, fn {_, until} -> until > now end)
    }
  end

  defp release(state, workspace) do
    case Map.pop(state.active, workspace) do
      {nil, _} ->
        state

      {{_pid, monitor}, active} ->
        Process.demonitor(monitor, [:flush])
        %{state | active: active}
    end
  end
end
