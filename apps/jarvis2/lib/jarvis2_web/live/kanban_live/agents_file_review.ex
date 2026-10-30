defmodule Jarvis2Web.KanbanLive.AgentsFileReview do
  use Phoenix.LiveComponent
  alias Jarvis2.Kanban

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign(:review, Kanban.agents_file_review(assigns.card))}
  end

  @impl true
  def handle_event("apply", _, socket) do
    case Kanban.apply_agents_file(socket.assigns.card) do
      {:ok, _} ->
        send(self(), {:arrangement_notice, :info, "AGENTS.md applied and card archived."})
        {:noreply, socket}

      {:error, message} ->
        send(self(), {:arrangement_notice, :error, message})
        {:noreply, assign(socket, :review, Kanban.agents_file_review(socket.assigns.card))}
    end
  end

  defp heading(:create), do: "Create AGENTS.md"
  defp heading(:update), do: "Update AGENTS.md"
  defp heading(:unchanged), do: "AGENTS.md unchanged"
  defp prefix(:del), do: "-"
  defp prefix(:ins), do: "+"
  defp prefix(:eq), do: " "
  defp show_line(line), do: String.trim_trailing(line, "\n")

  @impl true
  def render(assigns) do
    ~H"""
    <section id="agents-file-review">
      <%= case @review do %>
        <% {:error, message} -> %>
          <div class="banner banner-warn">
            {message} Reopen with feedback to refresh the proposal.
          </div>
          <a href={"/kanban/cards/#{@card.id}/reopen"}>Ask for changes…</a>
        <% {:ok, review} -> %>
          <h2>{heading(review.status)}</h2>
          <p>Writes to <code>{review.path}</code> in the run's checkout.</p>
          <p>Removes {review.removed_lines} lines, adds {review.added_lines}</p>
          <pre class="agents-file-diff"><%= for {kind, lines} <- review.diff, line <- lines do %><span class={"diff-#{kind}"}>{prefix(kind)}{show_line(line)}<%= if not String.ends_with?(line, "\n"), do: " (no newline at end of file)" %></span><% end %></pre>
          <h3>Agent's reasons</h3>
          <ul>
            <li :for={change <- review.changes}>
              {change["action"]}: {change["section"]} — {change["reason"]} ({change["source"]})
            </li>
          </ul>
          <details>
            <summary>Full proposed content</summary><div
              id={"agents-file-content-#{@card.id}"}
              phx-hook="Copy"
            >
              <button type="button">Copy</button><pre>{review.content}</pre>
            </div>
          </details>
          <div class="actions">
            <button
              type="button"
              phx-click="apply"
              phx-target={@myself}
              data-confirm={"Write AGENTS.md to #{review.path}?"}
            >Apply to {review.path}</button>
            <a href={"/kanban/cards/#{@card.id}/reopen"}>Ask for changes…</a>
          </div>
      <% end %>
    </section>
    """
  end
end
