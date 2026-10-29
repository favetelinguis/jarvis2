defmodule Jarvis2.Scenarios.ReviewDiff do
  @moduledoc """
  Review fan-out (U11): a human action starts a few reviewer agents beside the focused pane
  and stores their merged output on the blackboard as `review:latest`.
  """
  use GenServer
  require Logger
  alias Jarvis2.Herdr.Actions
  alias Jarvis2.MCP.Identity

  @cooldown_ms 60_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(_) do
    Jarvis2.Bus.subscribe("hook:action")
    {:ok, %{active: nil, until: nil}}
  end

  @impl true
  def handle_info({:jarvis2, "hook:action", %{id: "review-diff", body: body}}, state)
      when is_map(body) do
    context = if is_map(body["context"]), do: body["context"], else: %{}

    source =
      Identity.resolve(%{
        "x-herdr-pane" => context["focused_pane_id"],
        "x-herdr-workspace" => context["workspace_id"]
      })

    now = System.monotonic_time(:millisecond)

    cond do
      source.pane == "unknown" ->
        Logger.warning("Herdr review-diff requires a fresh known pane")
        {:noreply, state}

      state.active != nil or (state.until != nil and now < state.until) ->
        Logger.warning("Herdr review-diff is busy or cooling down")
        {:noreply, state}

      true ->
        parent = self()

        case Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn ->
               result =
                 try do
                   Actions.review_fanout(source, %{
                     focuses: Application.get_env(:jarvis2, :review_focuses, ["bugs", "tests"]),
                     kind: Application.get_env(:jarvis2, :task_agent_kind, "pi")
                   })
                 rescue
                   _ -> {:error, "review failed"}
                 catch
                   :exit, _ -> {:error, "review failed"}
                 end

               send(parent, {:finished, result})
             end) do
          {:ok, pid} ->
            {:noreply, %{state | active: {pid, Process.monitor(pid)}, until: now + @cooldown_ms}}

          {:error, _} ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:finished, result}, state) do
    case result do
      {:ok, %{reviews: reviews}} ->
        Jarvis2.State.put("review:latest", %{reviews: reviews})
        Logger.info("Herdr review-diff finished reviews=#{length(reviews)}")
        Jarvis2.Bus.publish("scenario:review_diff", %{reviews: length(reviews)})

      {:ok, %{dry_run: true}} ->
        :ok

      {:error, message} ->
        Logger.warning("Herdr review-diff failed: #{message}")
    end

    {:noreply, release(state)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{active: {_, ref}} = state),
    do: {:noreply, release(state)}

  def handle_info(_, state), do: {:noreply, state}

  defp release(%{active: nil} = state), do: state

  defp release(%{active: {_, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    %{state | active: nil}
  end
end
