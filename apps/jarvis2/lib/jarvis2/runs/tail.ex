defmodule Jarvis2.Runs.Tail do
  @moduledoc """
  Reads the terminal of a run's pane while someone is watching it and broadcasts changes on
  `"run:<id>:tail"`. One process per watched run; it stops when the last watcher goes away, so
  LiveViews never talk to the Herdr socket themselves.
  """
  use GenServer

  alias Jarvis2.Herdr.{Mirror, Socket}
  alias Jarvis2.Runs
  alias Jarvis2.Runs.Launcher

  @interval 1_500
  @lines 60
  @max_bytes 8_192

  def topic(run_id), do: "run:#{run_id}:tail"

  @doc "Starts tailing if needed and returns the latest text (or nil). The caller is the watcher."
  def watch(run_id) do
    pid =
      case DynamicSupervisor.start_child(Jarvis2.Runs.TailSupervisor, {__MODULE__, run_id}) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    GenServer.call(pid, {:watch, self()})
  end

  def start_link(run_id),
    do:
      GenServer.start_link(__MODULE__, run_id,
        name: {:via, Registry, {Jarvis2.Runs.TailRegistry, run_id}}
      )

  def child_spec(run_id),
    do: %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [run_id]},
      restart: :temporary
    }

  @impl true
  def init(run_id), do: {:ok, %{run_id: run_id, watchers: %{}, text: nil}}

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    watchers = Map.put_new_lazy(state.watchers, pid, fn -> Process.monitor(pid) end)
    if map_size(state.watchers) == 0, do: send(self(), :poll)
    {:reply, state.text, %{state | watchers: watchers}}
  end

  @impl true
  def handle_info(:poll, %{watchers: watchers} = state) when map_size(watchers) == 0,
    do: {:noreply, state}

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @interval)
    {:noreply, read(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    Process.demonitor(ref, [:flush])
    watchers = Map.delete(state.watchers, pid)

    if map_size(watchers) == 0,
      do: {:stop, :normal, state},
      else: {:noreply, %{state | watchers: watchers}}
  end

  defp read(state) do
    with %Runs.Run{pane_id: pane_id} = run when is_binary(pane_id) <- Runs.get_run(state.run_id),
         %{stale: false} = view <- mirror_view(),
         {_pane, _agent} <- Launcher.find(run, view),
         {:ok, %{"read" => %{"text" => text}}} when is_binary(text) <- read_pane(pane_id) do
      text = tail_of(text)

      if text != state.text do
        Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, topic(state.run_id), {:tail, text})
      end

      %{state | text: text}
    else
      _ -> state
    end
  end

  defp read_pane(pane_id) do
    server = Application.get_env(:jarvis2, :herdr_socket, Socket)
    params = %{pane_id: pane_id, source: "recent_unwrapped", lines: @lines, format: "text"}
    Socket.request("pane.read", params, server: server, timeout: 3_000)
  end

  defp mirror_view do
    Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))
  catch
    :exit, _ -> nil
  end

  defp tail_of(text) when byte_size(text) > @max_bytes,
    do:
      binary_part(text, byte_size(text) - @max_bytes, @max_bytes)
      |> String.replace(~r/\A[\x80-\xBF]+/, "")

  defp tail_of(text), do: text
end
