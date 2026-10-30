defmodule Jarvis2Web.KanbanLive.Graph do
  use Phoenix.LiveView, layout: {Jarvis2Web.Layouts, :app}, log: false
  alias Jarvis2.{Kanban, Runs, Settings}
  alias Jarvis2.Kanban.{Dependencies, Dependency, Graph}
  import Jarvis2Web.KanbanLive.GraphView, only: [graph_view: 1, state: 2]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Jarvis2.PubSub, Kanban.topic())
      Phoenix.PubSub.subscribe(Jarvis2.PubSub, Runs.topic())
    end

    {:ok, assign(socket, selected_id: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    default = Application.get_env(:jarvis2, :mix_project_dir, File.cwd!())
    cwd = params["cwd"] || default
    count = length(Kanban.graph(cwd).nodes)

    hide =
      case params["hide"] do
        "1" -> true
        "0" -> false
        _ -> count > 60
      end

    {:noreply,
     socket |> assign(cwd: cwd, hide: hide, lanes: params["lanes"] == "worktree") |> load()}
  end

  @impl true
  def handle_event("filters", params, socket) do
    query = %{
      "cwd" => params["cwd"] || socket.assigns.cwd,
      "hide" => if(params["hide"] == "1", do: "1", else: "0")
    }

    query = if params["lanes"] == "worktree", do: Map.put(query, "lanes", "worktree"), else: query
    {:noreply, push_patch(socket, to: "/kanban/graph?" <> URI.encode_query(query))}
  end

  def handle_event("select", %{"id" => id}, socket) do
    selected = Enum.find(socket.assigns.graph.nodes, &(&1.id == id))
    id = if(selected, do: id)

    {:noreply,
     assign(socket, selected_id: id, related: Graph.related(socket.assigns.graph.edges, id))}
  end

  def handle_event("start", %{"id" => id}, socket) do
    case Kanban.get_card(id) do
      %{cwd: cwd} = card when cwd == socket.assigns.cwd ->
        case Kanban.move(card, :agent) do
          {:ok, _} -> {:noreply, load(socket)}
          {:error, message} -> {:noreply, socket |> put_flash(:error, message) |> load()}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Card not found.")}
    end
  end

  def handle_event("arrange", _, socket), do: start_arrange(socket, false)
  def handle_event("rearrange", _, socket), do: start_arrange(socket, true)

  def handle_event("retry-arrange", _, %{assigns: %{arrange: nil}} = socket),
    do: {:noreply, put_flash(socket, :error, "Arrangement not found.")}

  def handle_event("retry-arrange", _, socket) do
    case Kanban.get_card(socket.assigns.arrange.id) |> Kanban.retry_arrange() do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Arrangement retry started.") |> load()}
      {:error, message} -> {:noreply, socket |> put_flash(:error, message) |> load()}
    end
  end

  defp start_arrange(socket, reset) do
    case Kanban.start_arrange(socket.assigns.cwd, rearrange: reset) do
      {:ok, card} ->
        {:noreply, socket |> put_flash(:info, "Arrangement started: #{card.title}.") |> load()}

      {:error, message} ->
        {:noreply, socket |> put_flash(:error, message) |> load()}
    end
  end

  @impl true
  def handle_info({:card, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:run, _}, socket), do: {:noreply, load(socket)}

  def handle_info({:arrangement_notice, type, message}, socket),
    do: {:noreply, socket |> put_flash(type, message) |> load()}

  defp load(socket) do
    graph = Kanban.graph(socket.assigns.cwd)
    arrange = open_arrange(graph.nodes)
    review = if arrange, do: Kanban.arrangement_review(arrange)

    proposal_ids =
      if review,
        do: Enum.flat_map(review.edges, &[&1.edge["card"], &1.edge["blocked_by"]]),
        else: []

    projects = Kanban.list_cards() |> Enum.map(& &1.cwd) |> Enum.uniq() |> Enum.sort()
    projects = Enum.uniq([socket.assigns.cwd | projects])

    visible = visible_nodes(graph, socket.assigns.hide, proposal_ids)
    ids = MapSet.new(visible, & &1.id)

    edges =
      Enum.filter(
        graph.edges,
        &(MapSet.member?(ids, &1.card_id) and MapSet.member?(ids, &1.blocked_by_card_id))
      )

    layout =
      Graph.layout(%{nodes: visible, edges: edges},
        lanes: if(socket.assigns.lanes, do: :worktree),
        force_ids: proposal_ids,
        rank_edges: proposed_ranks(review, ids)
      )

    ready = Kanban.ready(socket.assigns.cwd)

    unarranged =
      Enum.count(
        graph.nodes,
        &(&1.kind != :arrange and &1.column == :scratch and is_nil(&1.arranged_at))
      )

    proposals = if review, do: Graph.proposal_paths(layout, review), else: []

    assign(socket,
      graph: graph,
      drawing: layout,
      projects: projects,
      ready: ready,
      arrange: arrange,
      review: review,
      proposals: proposals,
      unarranged: unarranged,
      related: Graph.related(graph.edges, socket.assigns.selected_id),
      highlight_css: highlight_css(layout, graph),
      threshold: Settings.get().arrange_nudge_threshold
    )
  end

  defp proposed_ranks(nil, _ids), do: []

  defp proposed_ranks(review, ids) do
    for item <- review.edges,
        is_nil(item.error),
        MapSet.member?(ids, item.edge["card"]),
        MapSet.member?(ids, item.edge["blocked_by"]) do
      %Dependency{card_id: item.edge["card"], blocked_by_card_id: item.edge["blocked_by"]}
    end
  end

  defp open_arrange(nodes) do
    case Enum.find(nodes, &(&1.kind == :arrange and &1.column != :archive)) do
      nil -> nil
      card -> Kanban.get_card(card.id)
    end
  end

  defp visible_nodes(graph, hide, proposal_ids) do
    required =
      graph.edges
      |> Enum.filter(
        &(not Dependencies.satisfied?(&1) and &1.card.column not in [:done, :archive])
      )
      |> MapSet.new(& &1.blocked_by_card_id)

    Enum.filter(graph.nodes, fn card ->
      card.kind != :arrange and
        (not hide or card.column not in [:done, :archive] or MapSet.member?(required, card.id) or
           card.id in proposal_ids)
    end)
  end

  defp highlight_css(layout, graph) do
    Enum.map_join(layout.nodes, "\n", fn node ->
      related = Graph.related(graph.edges, node.card.id)
      nodes = Enum.map_join(related, ",", &"#graph-node-#{&1}")

      edges =
        graph.edges
        |> Enum.filter(
          &(MapSet.member?(related, &1.card_id) and MapSet.member?(related, &1.blocked_by_card_id))
        )
        |> Enum.map_join(",", &"#graph-edge-#{&1.blocked_by_card_id}-#{&1.card_id}")

      active = "#dependency-graph:has(#graph-node-#{node.card.id}:is(:hover,:focus))"
      selectors = Enum.reject([nodes, edges], &(&1 == "")) |> Enum.join(",")

      "#{active} .graph-node,#{active} .graph-edge {opacity:.2} #{active} :is(#{selectors}) {opacity:1} #{active} :is(#{selectors}) .graph-edge {opacity:1;stroke:#2a7de1;stroke-width:4}"
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1><.link navigate="/kanban">Kanban</.link> › Graph</h1>
    <form id="graph-filters" phx-change="filters">
      <label>Project
      <select name="cwd"><option :for={cwd <- @projects} value={cwd} selected={cwd == @cwd}>
        {cwd}
      </option></select></label>
      <label><input type="checkbox" name="hide" value="1" checked={@hide} /> Hide done and archived</label>
      <label><input type="checkbox" name="lanes" value="worktree" checked={@lanes} />
      Group by worktree</label>
    </form>
    <p :if={@threshold > 0 && @unarranged >= @threshold} class="banner banner-warn">
      {@unarranged} Scratch cards have not been arranged. Arrange proposes dependencies for your review.
    </p>
    <div class="actions">
      <button
        type="button"
        phx-click="arrange"
        disabled={!!@arrange || @unarranged == 0}
        class={@threshold > 0 && @unarranged >= @threshold && "arrange-emphasis"}
        data-confirm={"Start an Arrange agent for #{min(@unarranged, 50)} unarranged cards in #{@cwd}? It reads card titles and bodies and proposes dependencies. It changes nothing until you accept."}
      >{if @unarranged == 0, do: "All cards arranged", else: "Arrange #{min(@unarranged, 50)} cards…"}</button>
      <button
        type="button"
        phx-click="rearrange"
        disabled={!!@arrange}
        data-confirm="Remove arranger-created dependencies from Scratch cards and start a new arrangement? Human and harness dependencies are kept."
      >Re-arrange</button>
      <.link
        :if={@arrange}
        navigate={
          if(@arrange.column == :awaiting_user,
            do: "/kanban/cards/#{@arrange.id}/answer",
            else: "/kanban/cards/#{@arrange.id}"
          )
        }
      >
        {cond do
          @arrange.column == :awaiting_user ->
            "Arrangement needs answers"

          @arrange.column == :done ->
            "Arrangement ready for review"

          @arrange.column == :scratch ||
              (@arrange.run && @arrange.run.status in [:failed, :lost, :stopped]) ->
            "Arrangement failed or stopped"

          true ->
            "Arranging #{length(@arrange.arrange_snapshot["considered"])} cards…"
        end}
      </.link>
      <button
        :if={
          @arrange &&
            (@arrange.column == :scratch ||
               (@arrange.column == :agent && @arrange.run &&
                  @arrange.run.status in [:failed, :lost, :stopped]))
        }
        type="button"
        phx-click="retry-arrange"
      >Retry</button>
    </div>
    <div id="arrangement-context">
      <style>
        {@highlight_css}
      </style>
      <div class="graph-page">
        <div class="graph-scroll">
          <.graph_view
            drawing={@drawing}
            graph={@graph}
            lanes={@lanes}
            proposals={@proposals}
            selected_id={@selected_id}
            related={@related}
          />
        </div>
        <aside>
          <section id="ready-now">
            <h2>Ready now ({length(@ready)})</h2>
            <ul>
              <li :for={card <- @ready}>
                <.link navigate={"/kanban/cards/#{card.id}"}>{card.title}</.link>
                <button type="button" phx-click="start" phx-value-id={card.id}>Start</button>
              </li>
            </ul>
          </section>
          <section id="not-connected">
            <h2>Not connected ({length(@drawing.disconnected)})</h2>
            <ul>
              <li :for={card <- @drawing.disconnected}>
                <.link navigate={"/kanban/cards/#{card.id}"}>{card.title}</.link>
              </li>
            </ul>
          </section>
        </aside>
      </div>
      <.live_component
        :if={@review}
        module={Jarvis2Web.KanbanLive.ArrangeReview}
        id={"review-#{@arrange.id}"}
        card={@arrange}
        graph={@graph}
      />
      <style :for={item <- if(@review, do: @review.edges, else: [])}>
        {"#arrangement-context:has(#arrangement-row-#{item.index}:hover) #proposal-#{item.index} path { stroke-width: 6; }"}
      </style>
    </div>
    <aside
      :if={card = Enum.find(@graph.nodes, &(&1.id == @selected_id))}
      id="graph-panel"
      class="kanban-panel"
    >
      <h2>{card.title}</h2><p>{elem(state(card, @graph), 0)}</p>
      <.link navigate={"/kanban/cards/#{card.id}"}>Open card</.link>
      <.live_component
        module={Jarvis2Web.KanbanLive.Dependencies}
        id={"graph-dependencies-#{card.id}"}
        card={card}
        graph={@graph}
      />
    </aside>
    """
  end
end
