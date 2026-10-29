defmodule Jarvis2.Herdr.Events do
  @moduledoc "Manages lifecycle and per-agent Herdr event subscriptions."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{EventStream, Mirror}

  @lifecycle ~w(workspace.created workspace.updated workspace.metadata_updated workspace.renamed workspace.moved workspace.reordered workspace.closed workspace.focused tab.created tab.closed tab.focused tab.renamed tab.moved pane.created pane.updated pane.closed pane.focused pane.moved pane.exited pane.agent_detected layout.updated worktree.created worktree.opened worktree.removed)
  @names Map.new(@lifecycle, fn name -> {String.replace(name, ".", "_"), name} end)

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "mirror:updated")

    state = %{
      mirror: Keyword.get(opts, :mirror, Mirror),
      path:
        Keyword.get(opts, :path) || System.get_env("HERDR_SOCKET_PATH") ||
          Path.expand("~/.config/herdr/herdr.sock"),
      retry_ms: Keyword.get(opts, :retry_ms, 200),
      main: nil,
      panes: %{},
      pending: MapSet.new(),
      online: false,
      timeline: %{}
    }

    {:ok, start_main(state)}
  end

  @impl true
  def handle_info({:stream_ready, pid}, state) do
    if known?(state, pid) do
      state = %{state | pending: MapSet.delete(state.pending, pid)} |> sync_online()
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:stream_down, pid, reason}, state) do
    if known?(state, pid) do
      Logger.warning("Herdr event subscription disconnected: #{inspect(reason)}")
      state = %{state | pending: MapSet.put(state.pending, pid)} |> sync_online()
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:stream_missing, pid}, state) do
    state = remove_pane(state, pid) |> sync_online()
    if state.online, do: Mirror.online(state.mirror, Map.keys(state.panes))
    {:noreply, state}
  end

  def handle_info({:stream_event, pid, name, data}, state) do
    if known?(state, pid) do
      name = Map.get(@names, name, name)
      event = %{delivery: "socket", type: name, data: data}

      pane =
        data["pane_id"] ||
          case data["pane"] do
            %{"pane_id" => id} -> id
            _ -> nil
          end

      Logger.info("Herdr event source=socket type=#{inspect(name)} pane=#{inspect(pane)}")

      Jarvis2.Journal.record(%{source: :herdr, type: name, payload: data})

      topic = "herdr:" <> name
      Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, topic, {:jarvis2, topic, event})

      Mirror.invalidate(state.mirror)
      {:noreply, track_status(state, name, data)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:jarvis2, "mirror:updated", %{source: source, view: %{snapshot: snapshot}}},
        state
      ) do
    if source == GenServer.whereis(state.mirror) and state.online and is_map(snapshot) do
      ids =
        snapshot["agents"]
        |> Enum.map(& &1["pane_id"])
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      old_panes = MapSet.new(Map.keys(state.panes))
      state = state |> seed_timeline(snapshot["agents"]) |> reconcile_panes(ids) |> sync_online()

      if state.online and old_panes != MapSet.new(Map.keys(state.panes)),
        do: Mirror.online(state.mirror, Map.keys(state.panes))

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.main ->
        Logger.warning("Herdr lifecycle stream exited: #{inspect(reason)}")

        state =
          %{state | main: nil, pending: MapSet.delete(state.pending, pid)}
          |> sync_online()
          |> start_main()

        {:noreply, state}

      known?(state, pid) ->
        state = remove_pane(state, pid) |> sync_online()
        if state.online, do: Mirror.online(state.mirror, Map.keys(state.panes))
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start_main(state) do
    subscriptions = Enum.map(@lifecycle, &%{type: &1})

    {:ok, pid} =
      EventStream.start_link(
        owner: self(),
        path: state.path,
        subscriptions: subscriptions,
        retry_ms: state.retry_ms
      )

    %{state | main: pid, pending: MapSet.put(state.pending, pid)}
  end

  defp reconcile_panes(state, desired) do
    state =
      Enum.reduce(state.panes, state, fn {id, pid}, acc ->
        if MapSet.member?(desired, id), do: acc, else: stop_pane(acc, id, pid)
      end)

    Enum.reduce(desired, state, fn id, acc ->
      if Map.has_key?(acc.panes, id) do
        acc
      else
        subscriptions = [
          %{type: "pane.agent_status_changed", pane_id: id},
          %{
            type: "pane.output_matched",
            pane_id: id,
            source: "recent_unwrapped",
            match: %{type: "regex", value: "(?i)error|panic|FAIL"}
          }
        ]

        {:ok, pid} =
          EventStream.start_link(
            owner: self(),
            path: acc.path,
            subscriptions: subscriptions,
            retry_ms: acc.retry_ms
          )

        %{acc | panes: Map.put(acc.panes, id, pid), pending: MapSet.put(acc.pending, pid)}
      end
    end)
  end

  defp stop_pane(state, id, pid) do
    try do
      GenServer.stop(pid, :normal)
    catch
      :exit, _ -> :ok
    end

    %{
      state
      | panes: Map.delete(state.panes, id),
        pending: MapSet.delete(state.pending, pid),
        timeline: Map.delete(state.timeline, id)
    }
  end

  defp remove_pane(state, pid) do
    case Enum.find(state.panes, fn {_id, child} -> child == pid end) do
      {id, _} ->
        %{
          state
          | panes: Map.delete(state.panes, id),
            pending: MapSet.delete(state.pending, pid),
            timeline: Map.delete(state.timeline, id)
        }

      nil ->
        state
    end
  end

  defp known?(state, pid), do: pid == state.main or pid in Map.values(state.panes)

  defp sync_online(state) do
    online = not is_nil(state.main) and MapSet.size(state.pending) == 0

    cond do
      online and not state.online -> Mirror.online(state.mirror, Map.keys(state.panes))
      not online and state.online -> Mirror.offline(state.mirror)
      true -> :ok
    end

    %{state | online: online}
  end

  defp seed_timeline(state, agents) do
    now = System.monotonic_time(:millisecond)

    timeline =
      Enum.reduce(agents, state.timeline, fn
        %{"pane_id" => id, "agent_status" => status}, acc
        when is_binary(id) and is_binary(status) ->
          Map.put_new(acc, id, {status, now})

        _, acc ->
          acc
      end)

    %{state | timeline: timeline}
  end

  defp track_status(
         state,
         "pane.agent_status_changed",
         %{"pane_id" => id, "agent_status" => status} = data
       ) do
    now = System.monotonic_time(:millisecond)

    case state.timeline[id] do
      {^status, _time} ->
        state

      {previous, time} ->
        Logger.info(
          "Herdr agent pane=#{inspect(id)} agent=#{inspect(data["agent"])} #{previous}→#{status} previous_ms=#{now - time}"
        )

        %{state | timeline: Map.put(state.timeline, id, {status, now})}

      nil ->
        %{state | timeline: Map.put(state.timeline, id, {status, now})}
    end
  end

  defp track_status(state, _, _), do: state
end
