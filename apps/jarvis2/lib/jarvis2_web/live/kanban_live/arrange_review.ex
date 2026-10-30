defmodule Jarvis2Web.KanbanLive.ArrangeReview do
  use Phoenix.LiveComponent
  alias Jarvis2.Kanban

  @impl true
  def update(assigns, socket) do
    review = Kanban.arrangement_review(assigns.card)

    selected = selected(socket.assigns, assigns.card, review)

    {:ok, socket |> assign(assigns) |> assign(review: review, selected: selected)}
  end

  defp selected(%{card: %{id: id}, selected: selected}, %{id: id}, _review), do: selected
  defp selected(_, _, nil), do: []
  defp selected(_, _, review), do: for(item <- review.edges, is_nil(item.error), do: item.index)

  @impl true
  def handle_event("select", params, socket) do
    {:noreply, assign(socket, selected: selection(params))}
  end

  def handle_event("accept", params, socket) do
    case Kanban.apply_arrangement(socket.assigns.card, selection(params)) do
      {:ok, result} ->
        details = Enum.map_join(result.skipped, "; ", &"proposal #{&1.index + 1}: #{&1.reason}")
        message = "Applied #{result.applied} dependencies; skipped #{length(result.skipped)}."

        send(
          self(),
          {:arrangement_notice, :info, message <> if(details == "", do: "", else: " " <> details)}
        )

      {:error, message} ->
        send(self(), {:arrangement_notice, :error, message})
    end

    {:noreply, socket}
  end

  def handle_event("dismiss", _, socket) do
    case Kanban.move(socket.assigns.card, :archive) do
      {:ok, _} ->
        send(
          self(),
          {:arrangement_notice, :info, "Arrangement dismissed; cards remain unarranged."}
        )

      {:error, message} ->
        send(self(), {:arrangement_notice, :error, message})
    end

    {:noreply, socket}
  end

  defp selection(params) do
    params
    |> Map.get("selected", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        case Integer.parse(value) do
          {index, ""} -> [index]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp title(graph, id),
    do: Enum.find_value(graph.nodes, id, fn c -> if c.id == id, do: c.title end)

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <form
        :if={@review}
        id="arrangement-review"
        phx-change="select"
        phx-submit="accept"
        phx-target={@myself}
      >
        <h2>
          Arrange proposes {length(@review.edges)} dependencies for {length(@review.considered)} cards
        </h2>
        <p>Only checked, still-valid edges will be added. Invalid proposals are shown in red.</p>
        <label :for={item <- @review.edges} id={"arrangement-row-#{item.index}"} class="check">
          <input
            type="checkbox"
            name="selected[]"
            value={item.index}
            checked={item.index in @selected}
            disabled={!!item.error}
          />
          <span>
            {title(@graph, item.edge["card"])} depends on {title(@graph, item.edge["blocked_by"])} (needs {item.edge[
              "needs"
            ]}) — {item.edge["reason"]}
            <strong :if={item.error} class="field-error">{item.error}</strong>
          </span>
        </label>
        <p :for={id <- @review.considered} :if={!Enum.any?(@review.edges, &(&1.edge["card"] == id))}>
          {title(@graph, id)} — considered, no dependency
        </p>
        <div class="actions">
          <button type="submit">Accept {length(@selected)}</button>
          <a href={"/kanban/cards/#{@card.id}/reopen"}>Ask for changes…</a>
          <button
            type="button"
            phx-click="dismiss"
            phx-target={@myself}
            data-confirm="Dismiss this arrangement without changing dependencies?"
          >Dismiss</button>
        </div>
      </form>
    </div>
    """
  end
end
