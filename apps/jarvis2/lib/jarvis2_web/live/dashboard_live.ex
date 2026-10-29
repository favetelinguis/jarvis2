defmodule Jarvis2Web.DashboardLive do
  use Jarvis2Web, :live_view

  alias Jarvis2.Herdr.Mirror
  alias Jarvis2.Journal

  @event_limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Jarvis2.PubSub, "mirror:updated")
      Phoenix.PubSub.subscribe(Jarvis2.PubSub, Journal.topic())
    end

    {:ok,
     socket
     |> assign(:view, Mirror.get(mirror()))
     |> assign(:live?, Application.get_env(:jarvis2, :live, false))
     |> stream(:events, Journal.recent(limit: @event_limit) |> Enum.reverse())}
  end

  @impl true
  def handle_info({:jarvis2, "mirror:updated", %{source: source, view: view}}, socket) do
    if source == GenServer.whereis(mirror()),
      do: {:noreply, assign(socket, :view, view)},
      else: {:noreply, socket}
  end

  def handle_info({:event, event}, socket),
    do: {:noreply, stream_insert(socket, :events, event, at: 0, limit: @event_limit)}

  defp mirror, do: Application.get_env(:jarvis2, :mirror, Mirror)

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Dashboard</h1>
    <div class={["banner", connection(@view) != :online && "banner-warn"]} id="connection">
      <.live_badge live={@live?} />
      <span>{connection_text(connection(@view))}</span>
      <span :if={diff = @view[:layout_diff]} class="muted">
        · layout {diff["status"]}, {length(diff["changes"] || [])} change(s)
      </span>
    </div>

    <section :if={snapshot = @view[:snapshot]} class="tree" id="session">
      <h2>Session</h2>
      <ul>
        <li :for={workspace <- snapshot["workspaces"] || []} id={"workspace-#{workspace["workspace_id"]}"}>
          <strong>{workspace["label"] || workspace["workspace_id"]}</strong>
          <ul>
            <li :for={tab <- tabs(snapshot, workspace)} id={"tab-#{tab["tab_id"]}"}>
              {tab["label"] || tab["tab_id"]}
              <ul>
                <li :for={pane <- panes(snapshot, tab)} id={"pane-#{pane["pane_id"]}"}>
                  <code>{pane["pane_id"]}</code>
                  <span class="muted">{pane["foreground_cwd"] || pane["cwd"]}</span>
                  <span :if={agent = agent_for(snapshot, pane)}>
                    {agent["name"] || agent["agent"]} <.status_badge status={agent["agent_status"]} />
                  </span>
                </li>
              </ul>
            </li>
          </ul>
        </li>
      </ul>
    </section>

    <section :if={snapshot = @view[:snapshot]} id="agents">
      <h2>Agents</h2>
      <table>
        <thead><tr><th>Name</th><th>Kind</th><th>Pane</th><th>Status</th></tr></thead>
        <tbody>
          <tr :for={agent <- snapshot["agents"] || []} id={"agent-#{agent["pane_id"]}"}>
            <td>{agent["name"]}</td>
            <td>{agent["agent"]}</td>
            <td><code>{agent["pane_id"]}</code></td>
            <td><.status_badge status={agent["agent_status"]} /></td>
          </tr>
        </tbody>
      </table>
    </section>

    <section id="events-section">
      <h2>Recent events</h2>
      <table>
        <thead><tr><th>Time</th><th>Source</th><th>Type</th><th>Outcome</th></tr></thead>
        <tbody id="events" phx-update="stream">
          <tr :for={{id, event} <- @streams.events} id={id}>
            <td>{Calendar.strftime(event.inserted_at, "%H:%M:%S")}</td>
            <td>{event.source}</td>
            <td>{event.type}</td>
            <td>{event.outcome}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp connection(%{snapshot: nil}), do: :waiting
  defp connection(%{stale: true}), do: :stale
  defp connection(_view), do: :online

  defp connection_text(:waiting), do: "Waiting for the Herdr session…"
  defp connection_text(:stale), do: "Herdr state is stale; refreshing."
  defp connection_text(:online), do: "Connected to Herdr."

  defp tabs(snapshot, workspace),
    do: Enum.filter(snapshot["tabs"] || [], &(&1["workspace_id"] == workspace["workspace_id"]))

  defp panes(snapshot, tab),
    do: Enum.filter(snapshot["panes"] || [], &(&1["tab_id"] == tab["tab_id"]))

  defp agent_for(snapshot, pane),
    do: Enum.find(snapshot["agents"] || [], &(&1["pane_id"] == pane["pane_id"]))
end
