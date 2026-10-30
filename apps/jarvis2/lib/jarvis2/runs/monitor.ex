defmodule Jarvis2.Runs.Monitor do
  @moduledoc "Keeps run statuses in step with the Herdr mirror, and reconciles runs after a restart."
  use GenServer
  require Logger

  alias Jarvis2.Herdr.Mirror

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "mirror:updated")
    Process.send_after(self(), :tick, 1_000)
    {:ok, %{seen: %{}}}
  end

  @impl true
  def handle_info({:jarvis2, "mirror:updated", %{source: source, view: view}}, state) do
    if source == GenServer.whereis(Application.get_env(:jarvis2, :mirror, Mirror)) do
      {:noreply, %{state | seen: apply_view(view, state.seen)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1_000)

    view =
      try do
        Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))
      catch
        :exit, _ -> nil
      end

    {:noreply, %{state | seen: apply_view(view, state.seen)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A failed reconcile must never take down the supervision tree; the next mirror update retries.
  defp apply_view(view, seen) do
    Jarvis2.Runs.apply_view(view, seen)
  rescue
    error ->
      Logger.warning("run monitor failed: #{inspect(error.__struct__)}")
      seen
  end
end
