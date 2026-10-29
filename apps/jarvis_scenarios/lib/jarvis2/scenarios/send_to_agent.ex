defmodule Jarvis2.Scenarios.SendToAgent do
  @moduledoc "Choose and prompt a same-workspace agent from a human action."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Mirror}
  alias Jarvis2.MCP.{Identity, Picker}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(_) do
    Jarvis2.Bus.subscribe("hook:action")
    {:ok, %{active: %{}}}
  end

  @impl true
  def handle_info({:jarvis2, "hook:action", %{id: "send-to-agent", body: body}}, state) do
    context = if is_map(body["context"]), do: body["context"], else: %{}

    caller =
      Identity.resolve(%{
        "x-herdr-pane" => context["focused_pane_id"],
        "x-herdr-workspace" => context["workspace_id"]
      })

    cond do
      caller.pane == "unknown" or not is_binary(caller.agent_kind) ->
        Logger.warning("Herdr send-to-agent requires a recognized caller")
        {:noreply, state}

      Map.has_key?(state.active, caller.pane) ->
        Logger.warning("Herdr send-to-agent already active for caller")
        {:noreply, state}

      not live?() ->
        Logger.info(
          "would choose and prompt a same-workspace agent caller=#{inspect(caller.pane)}"
        )

        {:noreply, state}

      true ->
        parent = self()

        case Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn ->
               outcome = run(caller)
               send(parent, {:finished, caller.pane, outcome})
             end) do
          {:ok, pid} ->
            monitor = Process.monitor(pid)
            {:noreply, put_in(state.active[caller.pane], {pid, monitor})}

          {:error, _} ->
            Logger.warning("Herdr send-to-agent could not start")
            {:noreply, state}
        end
    end
  end

  def handle_info({:finished, pane, outcome}, state) do
    Logger.info("Herdr send-to-agent caller=#{inspect(pane)} outcome=#{outcome}")
    Jarvis2.Bus.publish("scenario:send_to_agent", %{pane: pane, outcome: outcome})
    {:noreply, release(state, pane)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    pane =
      Enum.find_value(state.active, fn {pane, {_pid, monitor}} -> if ref == monitor, do: pane end)

    if pane, do: {:noreply, release(state, pane)}, else: {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp run(caller) do
    mirror = Application.get_env(:jarvis2, :mirror, Mirror)

    case Mirror.get(mirror) do
      %{stale: false, snapshot: %{"agents" => agents}} when is_list(agents) ->
        candidates =
          agents
          |> Enum.filter(fn agent ->
            is_map(agent) and agent["workspace_id"] == caller.workspace and
              agent["pane_id"] != caller.pane and
              is_binary(agent["pane_id"]) and byte_size(agent["pane_id"]) in 1..128 and
              is_binary(agent["agent"]) and agent["agent_status"] in ["idle", "done"] and
              agent["interactive_ready"] != false
          end)
          |> Enum.take(10)

        choices = Enum.map(candidates, & &1["pane_id"])

        with true <- choices != [],
             {:ok, %{answer: choice}} when is_binary(choice) <-
               Picker.ask("Send to which agent?", choices, 60, caller),
             index when is_integer(index) <- Enum.find_index(choices, &(&1 == choice)),
             {:ok, %{answer: text}} when is_binary(text) and text != "" <-
               Picker.ask("Message for the agent:", [], 60, caller),
             {:ok, _} <-
               Actions.prompt(caller, Enum.at(candidates, index)["pane_id"], text, false,
                 server: Application.get_env(:jarvis2, :herdr_socket, Jarvis2.Herdr.Socket)
               ) do
          :ok
        else
          _ -> :cancelled_or_failed
        end

      _ ->
        :cancelled_or_failed
    end
  catch
    :exit, _ -> :cancelled_or_failed
  end

  defp live? do
    scenarios = Application.get_env(:jarvis2, :live_scenarios, [])

    Application.get_env(:jarvis2, :live, false) and :human_picker in scenarios and
      :agent_prompt in scenarios
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
