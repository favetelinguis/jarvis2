defmodule Jarvis2Web.KanbanLive.Dependencies do
  use Phoenix.LiveComponent
  alias Jarvis2.Kanban
  alias Jarvis2.Kanban.{Dependencies, Kind}

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign_new(:error, fn -> nil end)}
  end

  @impl true
  def handle_event("add", %{"blocked_by" => id, "needs" => needs}, socket) do
    card = socket.assigns.card

    case Kanban.get_card(id) do
      nil ->
        {:noreply, assign(socket, error: "Card not found.")}

      prerequisite ->
        case Kanban.add_dependency(card, prerequisite, needs: needs) do
          {:ok, _} -> {:noreply, assign(socket, error: nil)}
          {:error, reason} -> {:noreply, assign(socket, error: reason)}
        end
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Kanban.get_card(id) do
      nil ->
        {:noreply, assign(socket, error: "Card not found.")}

      prerequisite ->
        case Kanban.remove_dependency(socket.assigns.card, prerequisite) do
          {:ok, _} -> {:noreply, assign(socket, error: nil)}
          {:error, reason} -> {:noreply, assign(socket, error: reason)}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={"dependencies-#{@card.id}"}>
      <h3>Dependencies</h3>
      <h4>Blocked by</h4>
      <ul>
        <li :for={edge <- Enum.filter(@graph.edges, &(&1.card_id == @card.id))}>
          {if Dependencies.satisfied?(edge), do: "✓", else: "○"}
          <.link navigate={"/kanban/cards/#{edge.blocked_by_card.id}"}>{edge.blocked_by_card.title}</.link>
          {Kind.get(edge.blocked_by_card.kind).label} · {edge.blocked_by_card.worktree} needs {edge.needs} · {edge.source}
          <button
            :if={@card.column == :scratch}
            type="button"
            phx-click="remove"
            phx-target={@myself}
            phx-value-id={edge.blocked_by_card.id}
          >Remove</button>
        </li>
      </ul>
      <h4>Blocks</h4>
      <ul>
        <li :for={edge <- Enum.filter(@graph.edges, &(&1.blocked_by_card_id == @card.id))}>
          <.link navigate={"/kanban/cards/#{edge.card.id}"}>{edge.card.title}</.link>
          {Kind.get(edge.card.kind).label} · {edge.card.worktree}
        </li>
      </ul>
      <p :if={@card.column != :scratch}>Dependencies are frozen once a card starts.</p>
      <p :if={@error} class="field-error">{@error}</p>
      <form :if={@card.column == :scratch} id="dependency-form" phx-submit="add" phx-target={@myself}>
        <label>
          Add dependency
          <select id="dependency-prerequisite" name="blocked_by" required>
            <option value="">Select a card</option>
            <option :for={candidate <- Dependencies.candidates(@card, @graph)} value={candidate.id}>
              {candidate.title} · {candidate.worktree}
            </option>
          </select>
        </label>
        <label>Needs
        <select name="needs"><option value="done">done</option><option value="plan">plan</option></select></label>
        <button type="submit">Add</button>
      </form>
    </section>
    """
  end
end
