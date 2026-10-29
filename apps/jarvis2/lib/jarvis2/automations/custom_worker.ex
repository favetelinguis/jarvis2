defmodule Jarvis2.Automations.CustomWorker do
  @moduledoc "Best-effort Mix job status in the server's own Herdr pane."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Client, Socket}

  @agent "jarvis2-mix"
  @source "custom:jarvis2"

  def start(task) do
    if :custom_worker in Application.get_env(:jarvis2, :live_scenarios, []) do
      case GenServer.start(__MODULE__, {self(), task}) do
        {:ok, pid} -> pid
        _ -> nil
      end
    else
      nil
    end
  end

  def finish(nil, _result), do: :ok

  def finish(worker, result) do
    try do
      GenServer.call(worker, {:finish, result}, 5_000)
    catch
      :exit, _ -> :ok
    end
  end

  @impl true
  def init({owner, task}) do
    socket = Application.get_env(:jarvis2, :herdr_socket, Socket)

    with {:ok, _} <- Registry.register(Jarvis2.MixRegistry, :custom_worker, nil),
         {:ok, pane} <- find_server_pane(socket),
         {:ok, terminal} <- verify(pane, nil, socket, false),
         {:ok, _} <- report(pane, task, "working", socket) do
      ref = Process.monitor(owner)
      {:ok, %{owner: owner, ref: ref, pane: pane, terminal: terminal, task: task, socket: socket}}
    else
      _ ->
        Logger.warning("Herdr custom Mix worker was not confirmed; inspect the server pane")
        :ignore
    end
  end

  @impl true
  def handle_call({:finish, result}, {owner, _}, %{owner: owner} = state) do
    status = if match?({:ok, %{exit_status: 0}}, result), do: "idle", else: "blocked"
    finish_report(state, status)
    {:stop, :normal, :ok, state}
  end

  def handle_call(_, _from, state), do: {:reply, :error, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _}, %{ref: ref, owner: owner} = state) do
    finish_report(state, "blocked")
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp finish_report(state, status) do
    with {:ok, _} <- verify(state.pane, state.terminal, state.socket, true),
         {:ok, _} <- report(state.pane, state.task, status, state.socket) do
      :ok
    else
      _ -> Logger.warning("Herdr custom Mix worker status could not be updated safely")
    end
  end

  defp report(pane, task, status, socket) do
    Actions.call(
      :custom_worker,
      "pane.report_agent",
      %{
        pane_id: pane,
        source: @source,
        agent: @agent,
        state: status,
        message: "mix " <> task
      },
      server: socket,
      caller: "mix-worker",
      timeout: 1_000
    )
  end

  # The server may be outside Herdr or in another session; only a pane in the owned session
  # with this BEAM as its foreground process is eligible.
  defp find_server_pane(socket) do
    with {:ok, %{"snapshot" => %{"panes" => panes}}} when is_list(panes) and length(panes) <= 128 <-
           Client.snapshot(server: socket, timeout: 1_000),
         [pane] <- Enum.filter(panes, &server_pane?(&1, socket)) do
      {:ok, pane["pane_id"]}
    else
      _ -> {:error, :server_pane_unavailable}
    end
  end

  defp server_pane?(%{"pane_id" => pane}, socket) when is_binary(pane) do
    valid_id?(pane) and
      case Socket.request("pane.process_info", %{pane_id: pane}, server: socket, timeout: 1_000) do
        {:ok, %{"type" => "pane_process_info", "process_info" => info}} ->
          foreground_vm?(info, pane)

        _ ->
          false
      end
  end

  defp server_pane?(_, _), do: false

  defp verify(pane, expected, socket, require_worker) do
    with {:ok, first} <- snapshot(pane, expected, socket, require_worker),
         {:ok, %{"type" => "pane_process_info", "process_info" => info}} <-
           Socket.request("pane.process_info", %{pane_id: pane}, server: socket, timeout: 1_000),
         true <- foreground_vm?(info, pane),
         {:ok, ^first} <- snapshot(pane, first, socket, require_worker) do
      {:ok, first}
    else
      _ -> {:error, :unsafe_pane}
    end
  end

  defp snapshot(pane, expected, socket, require_worker) do
    with {:ok, %{"snapshot" => %{"panes" => panes, "agents" => agents}}}
         when is_list(panes) and is_list(agents) <-
           Client.snapshot(server: socket, timeout: 1_000),
         true <- Enum.all?(panes, &is_map/1) and Enum.all?(agents, &is_map/1),
         [found] <- Enum.filter(panes, &(&1["pane_id"] == pane)),
         terminal when is_binary(terminal) and byte_size(terminal) in 1..256 <-
           found["terminal_id"],
         workspace when is_binary(workspace) and byte_size(workspace) in 1..128 <-
           found["workspace_id"],
         true <- is_nil(expected) or terminal == expected,
         true <-
           worker_occupancy?(
             Enum.filter(agents, &(&1["pane_id"] == pane)),
             terminal,
             workspace,
             require_worker
           ) do
      {:ok, terminal}
    else
      _ -> {:error, :unsafe_pane}
    end
  end

  defp worker_occupancy?([], _, _, false), do: true

  defp worker_occupancy?(
         [%{"agent" => @agent, "terminal_id" => terminal, "workspace_id" => workspace}],
         terminal,
         workspace,
         _
       ),
       do: true

  defp worker_occupancy?(_, _, _, _), do: false

  defp foreground_vm?(
         %{
           "pane_id" => pane,
           "foreground_process_group_id" => group,
           "foreground_processes" => processes
         },
         pane
       )
       when is_integer(group) and group > 0 and is_list(processes) do
    case Integer.parse(System.pid()) do
      {pid, ""} -> Enum.any?(processes, &(is_map(&1) and &1["pid"] == pid))
      _ -> false
    end
  end

  defp foreground_vm?(_, _), do: false

  defp valid_id?(value), do: is_binary(value) and byte_size(value) in 1..128
end
