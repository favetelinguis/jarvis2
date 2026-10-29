defmodule Jarvis2Web.EventLive do
  use Jarvis2Web, :live_view

  alias Jarvis2.Journal

  @limit 200
  @sources [:herdr, :mcp, :ui, :automation]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Jarvis2.PubSub, Journal.topic())
    {:ok, assign(socket, sources: @sources, filters: [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:params, Map.take(params, ~w(source type run)))
     |> stream(:events, Enum.reverse(Journal.recent([limit: @limit] ++ filters)), reset: true)}
  end

  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    query = params |> Enum.reject(fn {_k, v} -> v == "" end) |> Map.new()
    {:noreply, push_patch(socket, to: "/events" <> query_string(query))}
  end

  @impl true
  def handle_info({:event, event}, socket) do
    if matches?(event, socket.assigns.filters),
      do: {:noreply, stream_insert(socket, :events, event, at: 0, limit: @limit)},
      else: {:noreply, socket}
  end

  defp filters(params) do
    [
      source: Enum.find(@sources, &(Atom.to_string(&1) == params["source"])),
      prefix: blank_to_nil(params["type"]),
      run_id:
        with(
          run when is_binary(run) <- params["run"],
          {:ok, id} <- Ecto.UUID.cast(run),
          do: id,
          else: (_ -> nil)
        )
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp matches?(event, filters) do
    Enum.all?(filters, fn
      {:source, source} -> event.source == source
      {:prefix, prefix} -> String.starts_with?(event.type, prefix)
      {:run_id, run_id} -> event.run_id == run_id
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  defp query_string(query) when map_size(query) == 0, do: ""
  defp query_string(query), do: "?" <> URI.encode_query(query)

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Events</h1>
    <.form
      for={%{}}
      as={:filter}
      id="filter-form"
      phx-change="filter"
      phx-submit="filter"
      class="filters"
    >
      <label>
        Source
        <select name="filter[source]">
          <option value="">all</option>
          <option :for={source <- @sources} value={source} selected={@params["source"] == "#{source}"}>
            {source}
          </option>
        </select>
      </label>
      <label>
        Type starts with
        <input
          type="text"
          name="filter[type]"
          value={@params["type"]}
          placeholder="tool. / run. / fleet."
          phx-debounce="300"
        />
      </label>
      <label>
        Run id <input type="text" name="filter[run]" value={@params["run"]} phx-debounce="300" />
      </label>
    </.form>

    <table>
      <thead>
        <tr>
          <th>Time</th><th>Source</th><th>Type</th><th>Outcome</th><th>Run</th><th>Details</th>
        </tr>
      </thead>
      <tbody id="events" phx-update="stream">
        <tr :for={{id, event} <- @streams.events} id={id}>
          <td>{Calendar.strftime(event.inserted_at, "%H:%M:%S")}</td>
          <td>{event.source}</td>
          <td>{event.type}</td>
          <td>{event.outcome}</td>
          <td>
            <span :if={event.run_id}>{String.slice(event.run_id, 0, 8)}</span>
          </td>
          <td><code class="payload">{Jason.encode!(event.payload)}</code></td>
        </tr>
      </tbody>
    </table>
    """
  end
end
