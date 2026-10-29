defmodule Jarvis2.Automations.OutputWatcher do
  @moduledoc "Route matched agent output to human notifications."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Socket}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "herdr:pane.output_matched")
    {:ok, %{socket: Keyword.get(opts, :socket, Socket)}}
  end

  @impl true
  def handle_info(
        {:jarvis2, "herdr:pane.output_matched",
         %{data: %{"pane_id" => pane, "matched_line" => line}}},
        state
      )
      when is_binary(pane) and is_binary(line) do
    if byte_size(pane) in 1..128 and byte_size(line) <= 65_536 do
      # Terminal output can contain credentials; log metadata, not the line itself.
      Logger.info("Herdr output match pane=#{inspect(pane)} line_bytes=#{byte_size(line)}")
      body = line |> String.slice(0, 1_000) |> String.replace(~r/[\x00-\x1f\x7f]/, " ")

      result =
        Actions.call(
          :output_watcher,
          "notification.show",
          %{title: "Agent output alert", body: body, sound: "none"},
          server: state.socket,
          caller: pane
        )

      Jarvis2.Journal.record(%{
        source: :automation,
        type: "automation.output_watcher",
        outcome: outcome(result),
        payload: %{pane: pane}
      })

      Phoenix.PubSub.local_broadcast(
        Jarvis2.PubSub,
        "scenario:output_watcher",
        {:jarvis2, "scenario:output_watcher", %{pane: pane, outcome: outcome(result)}}
      )
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, %{code: "disabled"}}), do: :refused
  defp outcome(_), do: :error
end
