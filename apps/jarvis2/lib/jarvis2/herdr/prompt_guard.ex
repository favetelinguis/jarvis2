defmodule Jarvis2.Herdr.PromptGuard do
  @moduledoc "Fail-closed, process-local policy for agent-to-agent prompts."
  use GenServer
  alias Jarvis2.Herdr.Mirror
  alias Jarvis2.MCP.Identity

  @window_ms 60_000
  @rate_limit 4
  @max_callers 256
  @max_edges 1_024
  @max_targets 1_024
  @success_cooldown_ms 5_000
  @uncertain_cooldown_ms 60_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def reserve(caller, target, mode, server \\ __MODULE__) do
    try do
      GenServer.call(server, {:reserve, caller, target, mode}, 3_000)
    rescue
      _ -> {:error, %{code: "guard_unavailable"}}
    catch
      :exit, _ -> {:error, %{code: "guard_unavailable"}}
    end
  end

  def finish(lease, outcome, server \\ __MODULE__),
    do: GenServer.cast(server, {:finish, lease, outcome})

  @impl true
  def init(_opts), do: {:ok, %{edges: MapSet.new(), rates: %{}, active: %{}, cooldowns: %{}}}

  @impl true
  def handle_call({:reserve, caller, target, mode}, {owner, _}, state)
      when is_map(caller) and is_binary(target) and mode in [:dry, :live] do
    mirror = Application.get_env(:jarvis2, :mirror, Mirror)
    now = System.monotonic_time(:millisecond)
    state = prune(state, now)

    with {:ok, target_pane} <- resolve(caller, target, get_view(mirror)),
         :ok <- allow(state, mode, caller.pane, target_pane) do
      key = {mode, target_pane}
      caller_key = {mode, caller.pane}
      lease = make_ref()
      monitor = Process.monitor(owner)
      active = Map.put(state.active, key, %{lease: lease, monitor: monitor})
      rates = Map.update(state.rates, caller_key, [now], &[now | &1])
      edges = MapSet.put(state.edges, {mode, caller.pane, target_pane})
      {:reply, {:ok, target_pane, lease}, %{state | active: active, rates: rates, edges: edges}}
    else
      {:error, code} -> {:reply, {:error, %{code: code}}, state}
    end
  end

  def handle_call({:reserve, _, _, _}, _from, state),
    do: {:reply, {:error, %{code: "invalid_caller_or_target"}}, state}

  @impl true
  def handle_cast({:finish, lease, outcome}, state),
    do: {:noreply, release(state, lease, outcome)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.active, fn {_key, item} -> item.monitor == monitor end) do
      {_, item} -> {:noreply, release(state, item.lease, :uncertain)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  # Jarvis2's own automations (for example the test loop) prompt as a named
  # system caller. They have no pane, so only the target is verified; the
  # workspace restriction is replaced by the automation's own scoping.
  defp resolve(
         %{system: name, pane: "system:" <> _},
         target,
         %{stale: false, snapshot: %{"panes" => panes, "agents" => agents}}
       )
       when is_binary(name) and name != "" and is_list(panes) and is_list(agents) and
              byte_size(target) in 1..128 do
    targets =
      Enum.filter(agents, &(is_map(&1) and (&1["pane_id"] == target or &1["name"] == target)))

    with [agent] <- targets,
         pane when is_map(pane) <-
           Enum.find(panes, &(is_map(&1) and &1["pane_id"] == agent["pane_id"])),
         true <- valid_occupant?(agent, pane),
         true <-
           agent["agent_status"] in ["idle", "done"] and agent["interactive_ready"] != false and
             agent["launch_pending"] != true do
      {:ok, agent["pane_id"]}
    else
      _ -> {:error, "target_unavailable"}
    end
  end

  defp resolve(
         caller,
         target,
         %{stale: false, snapshot: %{"panes" => panes, "agents" => agents}} = view
       )
       when is_list(panes) and is_list(agents) and byte_size(target) in 1..128 do
    headers = %{"x-herdr-pane" => caller[:pane], "x-herdr-workspace" => caller[:workspace]}
    verified = Identity.resolve(headers, view)
    source = Enum.find(agents, &(&1["pane_id"] == verified.pane))
    source_pane = Enum.find(panes, &(&1["pane_id"] == verified.pane))
    targets = Enum.filter(agents, &(&1["pane_id"] == target or &1["name"] == target))

    cond do
      verified.pane == "unknown" or verified.pane != caller[:pane] or
        verified.workspace != caller[:workspace] or verified.agent_kind != caller[:agent_kind] or
        verified.agent_name != caller[:agent_name] or not valid_occupant?(source, source_pane) ->
        {:error, "caller_unavailable"}

      length(targets) != 1 ->
        {:error, "target_unavailable"}

      true ->
        target_agent = hd(targets)
        target_pane = Enum.find(panes, &(&1["pane_id"] == target_agent["pane_id"]))

        cond do
          not valid_occupant?(target_agent, target_pane) ->
            {:error, "target_unavailable"}

          target_agent["pane_id"] == verified.pane ->
            {:error, "self_prompt_refused"}

          target_agent["workspace_id"] != verified.workspace ->
            {:error, "cross_workspace_refused"}

          target_agent["agent_status"] not in ["idle", "done"] or
            target_agent["interactive_ready"] == false or target_agent["launch_pending"] == true ->
            {:error, "target_not_ready"}

          true ->
            {:ok, target_agent["pane_id"]}
        end
    end
  end

  defp resolve(_, _, _), do: {:error, "caller_or_mirror_unavailable"}

  defp valid_occupant?(agent, pane) when is_map(agent) and is_map(pane) do
    is_binary(agent["agent"]) and is_binary(agent["pane_id"]) and
      is_binary(agent["terminal_id"]) and agent["terminal_id"] == pane["terminal_id"] and
      agent["workspace_id"] == pane["workspace_id"] and agent["tab_id"] == pane["tab_id"]
  end

  defp valid_occupant?(_, _), do: false

  defp allow(state, mode, caller, target) do
    target_key = {mode, target}
    caller_key = {mode, caller}
    edge = {mode, caller, target}

    cond do
      Map.has_key?(state.active, target_key) or Map.has_key?(state.cooldowns, target_key) ->
        {:error, "target_busy"}

      length(Map.get(state.rates, caller_key, [])) >= @rate_limit ->
        {:error, "rate_limited"}

      not Map.has_key?(state.rates, caller_key) and map_size(state.rates) >= @max_callers ->
        {:error, "guard_capacity"}

      map_size(state.active) + map_size(state.cooldowns) >= @max_targets ->
        {:error, "guard_capacity"}

      not MapSet.member?(state.edges, edge) and MapSet.size(state.edges) >= @max_edges ->
        {:error, "guard_capacity"}

      reachable?(state.edges, mode, [target], caller, MapSet.new()) ->
        {:error, "prompt_cycle_refused"}

      true ->
        :ok
    end
  end

  defp reachable?(_edges, _mode, [], _goal, _seen), do: false
  defp reachable?(_edges, _mode, [goal | _], goal, _seen), do: true

  defp reachable?(edges, mode, [current | rest], goal, seen) do
    if MapSet.member?(seen, current) do
      reachable?(edges, mode, rest, goal, seen)
    else
      neighbors = for {^mode, ^current, next} <- edges, do: next
      reachable?(edges, mode, neighbors ++ rest, goal, MapSet.put(seen, current))
    end
  end

  defp get_view(mirror) do
    try do
      GenServer.call(mirror, :get, 1_000)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp prune(state, now) do
    rates =
      state.rates
      |> Enum.map(fn {key, times} -> {key, Enum.filter(times, &(now - &1 < @window_ms))} end)
      |> Enum.reject(fn {_, times} -> times == [] end)
      |> Map.new()

    cooldowns = Map.filter(state.cooldowns, fn {_key, expires} -> expires > now end)
    %{state | rates: rates, cooldowns: cooldowns}
  end

  defp release(state, lease, outcome) do
    case Enum.find(state.active, fn {_key, item} -> item.lease == lease end) do
      {key, item} ->
        Process.demonitor(item.monitor, [:flush])
        delay = if outcome == :ok, do: @success_cooldown_ms, else: @uncertain_cooldown_ms

        %{
          state
          | active: Map.delete(state.active, key),
            cooldowns: Map.put(state.cooldowns, key, System.monotonic_time(:millisecond) + delay)
        }

      nil ->
        state
    end
  end
end
