defmodule Jarvis2.Journal.Pruner do
  @moduledoc "Periodically applies the journal retention policy and expires overdue questions."
  use GenServer

  @interval :timer.hours(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    {:ok, Keyword.get(opts, :interval, @interval), {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, interval) do
    # Questions that expired while the server was down are closed on boot.
    Jarvis2.Questions.expire_stale()
    {:noreply, schedule(interval)}
  end

  @impl true
  def handle_info(:prune, interval) do
    Jarvis2.Journal.prune()
    Jarvis2.Questions.expire_stale()
    {:noreply, schedule(interval)}
  end

  defp schedule(interval) do
    Process.send_after(self(), :prune, interval)
    interval
  end
end
