defmodule Jarvis2Web.RunLive.Index do
  use Jarvis2Web, :live_view

  alias Jarvis2.Runs
  alias Jarvis2.Runs.Run

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Jarvis2.PubSub, Runs.topic())
    {:ok, assign(socket, statuses: Run.statuses(), status: nil, runs: [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = Enum.find(Run.statuses(), &(Atom.to_string(&1) == params["status"]))
    {:noreply, socket |> assign(:status, status) |> load()}
  end

  @impl true
  def handle_info({:run, _run}, socket), do: {:noreply, load(socket)}

  defp load(socket), do: assign(socket, :runs, Runs.list_runs(status: socket.assigns.status))

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Runs</h1>
    <p>
      <.link navigate="/runs/new">New run</.link>
    </p>
    <nav id="status-filter" class="filter">
      <.link patch="/runs" class={is_nil(@status) && "current"}>all</.link>
      <.link
        :for={status <- @statuses}
        patch={"/runs?status=#{status}"}
        class={@status == status && "current"}
      >
        {status}
      </.link>
    </nav>
    <table>
      <thead>
        <tr>
          <th>Name</th><th>Status</th><th>Model</th><th>Pane</th><th>Started</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={run <- @runs} id={"run-#{run.id}"}>
          <td><.link navigate={"/runs/#{run.id}"}>{run.name}</.link></td>
          <td><.status_badge status={run.status} /></td>
          <td>{run.model} <span class="muted">({run.thinking})</span></td>
          <td><code>{run.pane_id}</code></td>
          <td>{Calendar.strftime(run.inserted_at, "%Y-%m-%d %H:%M:%S")}</td>
        </tr>
      </tbody>
    </table>
    <p :if={@runs == []} class="muted">No runs yet.</p>
    """
  end
end
