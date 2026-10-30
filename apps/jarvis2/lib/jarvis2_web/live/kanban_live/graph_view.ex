defmodule Jarvis2Web.KanbanLive.GraphView do
  @moduledoc false
  use Phoenix.Component
  alias Jarvis2.Kanban.{Dependencies, Kind}

  def state(card, graph) do
    blockers =
      graph.edges
      |> Enum.filter(&(&1.card_id == card.id))
      |> Enum.reject(&Dependencies.satisfied?/1)

    cond do
      card.column == :scratch and blockers != [] -> {"🔒 Blocked", length(blockers)}
      card.column == :scratch -> {"Ready", 0}
      card.column == :agent -> {"Running", length(blockers)}
      card.column == :awaiting_user -> {"Awaiting user", length(blockers)}
      card.column == :done -> {"Done", length(blockers)}
      true -> {"Archived", length(blockers)}
    end
  end

  def graph_view(assigns) do
    ~H"""
    <svg
      id="dependency-graph"
      width={@drawing.width}
      height={@drawing.height}
      viewBox={"0 0 #{@drawing.width} #{@drawing.height}"}
      role="group"
      aria-label="Card dependencies"
    >
      <defs>
        <pattern
          id="blocked-hatch"
          width="8"
          height="8"
          patternUnits="userSpaceOnUse"
          patternTransform="rotate(45)"
        >
          <rect width="8" height="8" fill="Canvas" />
          <line x1="0" y1="0" x2="0" y2="8" stroke="#888" stroke-opacity=".35" stroke-width="3" />
        </pattern>
        <marker
          id="graph-arrow"
          viewBox="0 0 10 10"
          refX="9"
          refY="5"
          markerWidth="6"
          markerHeight="6"
          orient="auto-start-reverse"
        >
          <path d="M 0 0 L 10 5 L 0 10 z" />
        </marker>
      </defs>
      <text :for={lane <- @drawing.lanes} x="4" y={lane.y - 10} class="graph-lane">
        {lane.name}
      </text>
      <g
        :for={path <- @drawing.edges}
        id={"graph-edge-#{path.edge.blocked_by_card_id}-#{path.edge.card_id}"}
      >
        <path
          d={path.path}
          class={[
            "graph-edge",
            Dependencies.satisfied?(path.edge) && "satisfied",
            @selected_id && MapSet.member?(@related, path.edge.card_id) &&
              MapSet.member?(@related, path.edge.blocked_by_card_id) && "related",
            @selected_id &&
              !(MapSet.member?(@related, path.edge.card_id) &&
                  MapSet.member?(@related, path.edge.blocked_by_card_id)) && "dimmed"
          ]}
          marker-end="url(#graph-arrow)"
        />
        <text :if={path.edge.needs == :plan} x={path.label_x} y={path.label_y - 5}>plan</text>
        <text
          :if={@lanes && path.edge.card.worktree != path.edge.blocked_by_card.worktree}
          x={path.label_x}
          y={path.label_y + 15}
        >
          ↗ other worktree
        </text>
      </g>
      <a
        :for={proposal <- @proposals}
        id={"proposal-#{proposal.proposal.index}"}
        href={"#arrangement-row-#{proposal.proposal.index}"}
      >
        <path
          d={proposal.path}
          class={["graph-proposal", proposal.proposal.error && "proposal-invalid"]}
          marker-end="url(#graph-arrow)"
        />
        <title>{proposal.proposal.error || proposal.proposal.edge["reason"]}</title>
      </a>
      <a
        :for={node <- @drawing.nodes}
        id={"graph-node-#{node.card.id}"}
        href="#graph-panel"
        phx-click="select"
        phx-value-id={node.card.id}
        data-kind={node.card.kind}
        class={[
          "graph-node",
          "state-#{node.card.column}",
          elem(state(node.card, @graph), 1) > 0 && "has-blockers",
          @selected_id && MapSet.member?(@related, node.card.id) && "related",
          @selected_id && !MapSet.member?(@related, node.card.id) && "dimmed"
        ]}
        aria-label={"#{node.card.title}, #{Kind.get(node.card.kind).label}, #{elem(state(node.card, @graph), 0)}, blocked by #{elem(state(node.card, @graph), 1)}"}
      >
        <rect x={node.x} y={node.y} width="200" height="80" rx="7" />
        <text x={node.x + 10} y={node.y + 23}>{String.slice(node.card.title, 0, 24)}</text>
        <text x={node.x + 10} y={node.y + 44}>
          {Kind.get(node.card.kind).label} · {node.card.worktree}
        </text>
        <text x={node.x + 10} y={node.y + 65}>{elem(state(node.card, @graph), 0)}</text>
      </a>
    </svg>
    """
  end
end
