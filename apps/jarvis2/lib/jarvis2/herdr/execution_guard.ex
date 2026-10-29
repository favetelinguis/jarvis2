defmodule Jarvis2.Herdr.ExecutionGuard do
  @moduledoc "Fail-closed, process-local limits for creating agent and command panes."
  use GenServer
  alias Jarvis2.Herdr.Mirror
  alias Jarvis2.MCP.Identity

  @window_ms 60_000
  @max_attempts 4
  @max_callers 256
  @max_active 8
  @uncertain_cooldown_ms 60_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def reserve(caller, mode, server \\ __MODULE__) do
    try do
      GenServer.call(server, {:reserve, caller, mode}, 3_000)
    rescue
      _ -> {:error, "execution guard unavailable"}
    catch
      :exit, _ -> {:error, "execution guard unavailable"}
    end
  end

  def finish(lease, outcome, server \\ __MODULE__) do
    try do
      GenServer.call(server, {:finish, lease, outcome}, 3_000)
    catch
      :exit, _ -> :ok
    end
  end

  def validate(caller, %{stale: false, snapshot: %{"panes" => panes, "agents" => agents}} = view)
      when is_map(caller) and is_list(panes) and is_list(agents) do
    if Enum.all?(panes, &is_map/1) and Enum.all?(agents, &is_map/1),
      do: validate_occupant(caller, view, panes, agents),
      else: {:error, "caller or mirror unavailable"}
  end

  def validate(_, _), do: {:error, "caller or mirror unavailable"}

  defp validate_occupant(caller, view, panes, agents) do
    verified =
      Identity.resolve(
        %{"x-herdr-pane" => caller[:pane], "x-herdr-workspace" => caller[:workspace]},
        view
      )

    pane = Enum.find(panes, &(&1["pane_id"] == verified.pane))
    agent = Enum.find(agents, &(&1["pane_id"] == verified.pane))

    if verified.pane != "unknown" and verified.pane == caller[:pane] and
         verified.workspace == caller[:workspace] and verified.tab == caller[:tab] and
         verified.agent_name == caller[:agent_name] and verified.agent_kind == caller[:agent_kind] and
         verified.cwd == caller[:cwd] and is_binary(verified.cwd) and
         Path.type(verified.cwd) == :absolute and
         File.dir?(verified.cwd) and is_map(pane) and is_map(agent) and
         is_binary(agent["agent"]) and is_binary(agent["terminal_id"]) and
         agent["terminal_id"] == pane["terminal_id"] and
         agent["workspace_id"] == pane["workspace_id"] and
         agent["tab_id"] == pane["tab_id"] do
      {:ok, verified}
    else
      {:error, "caller is unavailable or no longer a recognized agent"}
    end
  end

  @impl true
  def init(_), do: {:ok, %{active: %{}, rates: %{}, cooldowns: %{}}}

  @impl true
  def handle_call({:reserve, caller, mode}, {owner, _}, state) when mode in [:dry, :live] do
    now = System.monotonic_time(:millisecond)
    state = prune(state, now)
    mirror = Application.get_env(:jarvis2, :mirror, Mirror)

    view =
      try do
        GenServer.call(mirror, :get, 1_000)
      catch
        :exit, _ -> nil
      end

    with {:ok, verified} <- verify_caller(caller, view),
         :ok <- allow(state, mode, verified.pane) do
      key = {mode, verified.pane}
      lease = make_ref()
      entry = %{lease: lease, monitor: Process.monitor(owner)}
      active = Map.put(state.active, key, entry)
      rates = Map.update(state.rates, key, [now], &[now | &1])
      {:reply, {:ok, verified, lease}, %{state | active: active, rates: rates}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:reserve, _, _}, _, state),
    do: {:reply, {:error, "invalid execution request"}, state}

  def handle_call({:finish, lease, outcome}, _, state),
    do: {:reply, :ok, release(state, lease, outcome)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    case Enum.find(state.active, fn {_, entry} -> entry.monitor == monitor end) do
      {_, entry} -> {:noreply, release(state, entry.lease, :uncertain)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  # Jarvis2's own front ends (the UI, automations) act as a named system caller and have no pane to
  # verify; every other caller must still be a detected agent.
  defp verify_caller(%{system: name, pane: "system:" <> _} = caller, _view)
       when is_binary(name) and name != "",
       do: {:ok, caller}

  defp verify_caller(caller, view), do: validate(caller, view)

  defp allow(state, mode, caller) do
    key = {mode, caller}

    cond do
      Map.has_key?(state.active, key) or Map.has_key?(state.cooldowns, key) ->
        {:error, "caller execution is busy or cooling down"}

      length(Map.get(state.rates, key, [])) >= @max_attempts ->
        {:error, "execution rate limit exceeded"}

      not Map.has_key?(state.rates, key) and map_size(state.rates) >= @max_callers ->
        {:error, "execution guard capacity exceeded"}

      map_size(state.active) >= @max_active ->
        {:error, "execution guard capacity exceeded"}

      true ->
        :ok
    end
  end

  defp prune(state, now) do
    rates =
      state.rates
      |> Enum.map(fn {key, times} -> {key, Enum.filter(times, &(now - &1 < @window_ms))} end)
      |> Enum.reject(fn {_, times} -> times == [] end)
      |> Map.new()

    %{
      state
      | rates: rates,
        cooldowns: Map.filter(state.cooldowns, fn {_, expires} -> expires > now end)
    }
  end

  defp release(state, lease, outcome) do
    case Enum.find(state.active, fn {_, entry} -> entry.lease == lease end) do
      {key, entry} ->
        Process.demonitor(entry.monitor, [:flush])

        cooldowns =
          if outcome == :ok,
            do: state.cooldowns,
            else:
              Map.put(
                state.cooldowns,
                key,
                System.monotonic_time(:millisecond) + @uncertain_cooldown_ms
              )

        %{state | active: Map.delete(state.active, key), cooldowns: cooldowns}

      nil ->
        state
    end
  end
end
