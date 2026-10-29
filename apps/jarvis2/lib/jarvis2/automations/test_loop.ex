defmodule Jarvis2.Automations.TestLoop do
  @moduledoc """
  Test loop (U14): when an agent in a trusted Mix project finishes a turn, run `mix test` in
  a sibling pane and, on failure, prompt the agent with the output tail.

  It reuses the guarded `run_command` and prompt paths, so those scenarios must also be
  live for real effects. The loop stops after `@max_failures` consecutive failures per pane.
  """
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Mirror}
  alias Jarvis2.MCP.Identity

  @max_failures 3
  @min_interval_ms 20_000
  @max_active 2
  @max_panes 256
  @exit_pattern "JARVIS2_EXIT_[0-9]+"
  # printf keeps the marker out of the echoed command line, which cannot match the pattern.
  @command "mix test; printf 'JARVIS2_EXIT_%s\\n' \"$?\""
  @system "test-loop"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(_) do
    for topic <- ~w(herdr:pane.agent_status_changed herdr:pane.closed),
        do: Phoenix.PubSub.subscribe(Jarvis2.PubSub, topic)

    {:ok, %{panes: %{}, active: %{}}}
  end

  @impl true
  def handle_info(
        {:jarvis2, "herdr:pane.agent_status_changed",
         %{data: %{"pane_id" => pane, "agent_status" => status}}},
        state
      )
      when is_binary(pane) and byte_size(pane) in 1..128 and is_binary(status) do
    entry = Map.get(state.panes, pane, %{status: nil, failures: 0, last: nil})
    state = put_pane(state, pane, %{entry | status: status})

    if entry.status == "working" and status in ["idle", "done"],
      do: {:noreply, maybe_run(state, pane, entry)},
      else: {:noreply, state}
  end

  def handle_info({:jarvis2, "herdr:pane.closed", %{data: %{"pane_id" => pane}}}, state)
      when is_binary(pane),
      do: {:noreply, %{state | panes: Map.delete(state.panes, pane)}}

  def handle_info({:finished, pane, result}, state) do
    state = release(state, pane)

    state =
      case {result, state.panes[pane]} do
        {:passed, %{} = entry} -> put_pane(state, pane, %{entry | failures: 0})
        {:failed, %{} = entry} -> put_pane(state, pane, %{entry | failures: entry.failures + 1})
        _ -> state
      end

    Logger.info("Herdr test loop pane=#{inspect(pane)} result=#{result}")

    Jarvis2.Journal.record(%{
      source: :automation,
      type: "automation.test_loop",
      outcome: if(result == :passed, do: :ok, else: :error),
      payload: %{pane: pane, result: result}
    })

    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "scenario:test_loop",
      {:jarvis2, "scenario:test_loop", %{pane: pane, result: result}}
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    pane =
      Enum.find_value(state.active, fn {pane, {_pid, monitor}} -> if monitor == ref, do: pane end)

    if pane, do: {:noreply, release(state, pane)}, else: {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp maybe_run(state, pane, entry) do
    now = System.monotonic_time(:millisecond)

    cond do
      not enabled?() ->
        Logger.info("would run mix tests after an agent turn pane=#{inspect(pane)}")
        state

      Map.has_key?(state.active, pane) or map_size(state.active) >= @max_active ->
        state

      entry.failures >= @max_failures ->
        Logger.warning("Herdr test loop stopped after repeated failures pane=#{inspect(pane)}")
        state

      entry.last && now - entry.last < @min_interval_ms ->
        state

      true ->
        parent = self()

        case Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn ->
               result =
                 try do
                   run(pane)
                 rescue
                   _ -> :error
                 catch
                   :exit, _ -> :error
                 end

               send(parent, {:finished, pane, result})
             end) do
          {:ok, pid} ->
            state = put_in(state.active[pane], {pid, Process.monitor(pid)})
            put_pane(state, pane, %{entry | last: now, status: "idle"})

          {:error, _} ->
            state
        end
    end
  end

  defp run(pane) do
    with {:ok, caller} <- await_caller(pane, System.monotonic_time(:millisecond) + 5_000),
         true <- trusted_project?(caller.cwd) do
      args = %{command: @command, wait_for: {:regex, @exit_pattern}, timeout_s: 100}

      case Actions.run_command(caller, args) do
        {:ok, %{output: output} = result} when is_binary(output) ->
          Logger.info("Herdr test loop wait=#{result.wait}")
          handle_output(caller, output)

        {:ok, _} ->
          :skipped

        {:error, _} ->
          :error
      end
    else
      _ -> :skipped
    end
  end

  defp handle_output(caller, output) do
    case Regex.scan(~r/JARVIS2_EXIT_([0-9]+)/, output) do
      [] ->
        :unconfirmed

      matches ->
        case matches |> List.last() |> List.last() do
          "0" ->
            :passed

          code ->
            prompt(caller, code, output)
            :failed
        end
    end
  end

  defp prompt(caller, code, output) do
    text =
      "Jarvis2 ran `mix test` after your last turn and it failed (exit #{code}). " <>
        "Output tail:\n" <> clean_tail(output) <> "\nPlease fix the failures."

    Actions.prompt(
      %{pane: "system:" <> @system, system: @system, workspace: caller.workspace},
      caller.pane,
      text,
      false,
      server: Application.get_env(:jarvis2, :herdr_socket, Jarvis2.Herdr.Socket)
    )
  end

  @doc false
  def clean_tail(output) do
    output
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/, "")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F-\x9F]/u, "")
    |> String.replace(~r/JARVIS2_EXIT_[0-9]+/, "")
    |> String.slice(-3_000, 3_000)
  end

  defp await_caller(pane, deadline) do
    mirror = Application.get_env(:jarvis2, :mirror, Mirror)

    caller =
      case Mirror.get(mirror) do
        %{stale: false, snapshot: %{"panes" => panes, "agents" => agents}} = view ->
          with %{"workspace_id" => workspace} <- Enum.find(panes, &(&1["pane_id"] == pane)),
               %{"agent_status" => status} when status in ["idle", "done"] <-
                 Enum.find(agents, &(&1["pane_id"] == pane)) do
            Identity.resolve(%{"x-herdr-pane" => pane, "x-herdr-workspace" => workspace}, view)
          else
            _ -> nil
          end

        _ ->
          nil
      end

    cond do
      caller && caller.pane == pane && is_binary(caller.agent_kind) ->
        {:ok, caller}

      System.monotonic_time(:millisecond) >= deadline ->
        :error

      true ->
        Process.sleep(200)
        await_caller(pane, deadline)
    end
  end

  @doc false
  def trusted_project?(cwd) when is_binary(cwd) do
    cwd = Path.expand(cwd)

    roots =
      Application.get_env(:jarvis2, :test_loop_roots) ||
        [Application.get_env(:jarvis2, :mix_project_dir, File.cwd!())]

    Enum.any?(roots, fn root ->
      root = Path.expand(root)
      cwd == root or String.starts_with?(cwd, root <> "/")
    end) and File.regular?(Path.join(cwd, "mix.exs"))
  end

  def trusted_project?(_), do: false

  defp enabled?,
    do: :test_loop in Application.get_env(:jarvis2, :live_scenarios, [])

  defp put_pane(state, pane, entry) do
    if Map.has_key?(state.panes, pane) or map_size(state.panes) < @max_panes,
      do: put_in(state.panes[pane], entry),
      else: state
  end

  defp release(state, pane) do
    case Map.pop(state.active, pane) do
      {nil, _} ->
        state

      {{_pid, monitor}, active} ->
        Process.demonitor(monitor, [:flush])
        %{state | active: active}
    end
  end
end
