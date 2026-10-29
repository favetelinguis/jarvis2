defmodule Jarvis2.Scenarios.Attention do
  @moduledoc "Route blocked and completed agent states to human attention."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Socket}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    for topic <- ~w(herdr:pane.agent_status_changed herdr:pane.focused herdr:pane.closed),
        do: Phoenix.PubSub.subscribe(Jarvis2.PubSub, topic)

    {:ok, %{socket: Keyword.get(opts, :socket, Socket), active: MapSet.new(), timeline: %{}}}
  end

  @impl true
  def handle_info(
        {:jarvis2, "herdr:pane.agent_status_changed",
         %{data: %{"pane_id" => pane, "agent_status" => status}}},
        state
      )
      when is_binary(pane) and is_binary(status) do
    if byte_size(pane) in 1..128 and status in ~w(idle working blocked done unknown) do
      now = System.monotonic_time(:millisecond)

      case state.timeline[pane] do
        {^status, _} ->
          {:noreply, state}

        previous ->
          state = put_in(state.timeline[pane], {status, now})

          state =
            if status in ~w(blocked done),
              do: attention(state, pane, status, previous, now),
              else: clear(state, pane)

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:jarvis2, topic, %{data: %{"pane_id" => pane}}}, state)
      when topic in ["herdr:pane.focused", "herdr:pane.closed"] and is_binary(pane) do
    state = clear(state, pane)

    state =
      if topic == "herdr:pane.closed",
        do: %{state | timeline: Map.delete(state.timeline, pane)},
        else: state

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp attention(state, pane, status, previous, now) do
    duration =
      case previous do
        {_, time} -> now - time
        nil -> nil
      end

    Logger.info(
      "Herdr attention pane=#{inspect(pane)} state=#{status} previous_ms=#{inspect(duration)}"
    )

    sound = if status == "blocked", do: "request", else: "done"

    invoke(state, pane, "notification.show", %{
      title: "Agent #{status}",
      body: "Pane #{pane} is #{status}",
      sound: sound
    })

    invoke(state, pane, "client.window_title.set", %{title: "Jarvis2: agent #{status}"})

    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "scenario:attention",
      {:jarvis2, "scenario:attention", %{pane: pane, state: status, previous_ms: duration}}
    )

    %{state | active: MapSet.put(state.active, pane)}
  end

  defp clear(state, pane) do
    if MapSet.member?(state.active, pane) do
      active = MapSet.delete(state.active, pane)

      if MapSet.size(active) == 0 do
        invoke(state, pane, "client.window_title.clear", %{})
      else
        invoke(state, pane, "client.window_title.set", %{
          title: "Jarvis2: #{MapSet.size(active)} agents need attention"
        })
      end

      Phoenix.PubSub.local_broadcast(
        Jarvis2.PubSub,
        "scenario:attention",
        {:jarvis2, "scenario:attention", %{pane: pane, state: "cleared"}}
      )

      %{state | active: active}
    else
      state
    end
  end

  defp invoke(state, pane, method, params),
    do: Actions.call(:attention, method, params, server: state.socket, caller: pane)
end
