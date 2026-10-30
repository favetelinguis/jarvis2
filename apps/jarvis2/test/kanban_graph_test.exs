defmodule Jarvis2.KanbanGraphTest do
  use Jarvis2.DataCase, async: false
  alias Jarvis2.Kanban
  alias Jarvis2.Kanban.Graph

  defp card(title, worktree \\ "main") do
    {:ok, card} = Kanban.create_card(%{title: title, cwd: File.cwd!(), worktree: worktree})
    card
  end

  test "ranks connected cards by longest prerequisite path and separates loose cards" do
    a = card("A")
    b = card("B")
    c = card("C")
    loose = card("Loose")
    {:ok, _} = Kanban.add_dependency(b, a)
    {:ok, _} = Kanban.add_dependency(c, b)
    {:ok, _} = Kanban.add_dependency(c, a)
    layout = Graph.layout(Kanban.graph(a.cwd))
    positions = Map.new(layout.nodes, &{&1.card.id, &1})
    assert positions[a.id].rank == 0
    assert positions[b.id].rank == 1
    assert positions[c.id].rank == 2
    assert positions[a.id].x < positions[b.id].x
    assert positions[b.id].x < positions[c.id].x
    assert Enum.map(layout.disconnected, & &1.id) == [loose.id]
    assert length(layout.edges) == 3
    card("Another loose card")
    assert Graph.layout(Kanban.graph(a.cwd)).nodes == layout.nodes
  end

  test "valid proposed edges influence execution order without becoming live edges" do
    a = card("A")
    b = card("B")
    proposed = %Jarvis2.Kanban.Dependency{card_id: b.id, blocked_by_card_id: a.id}
    layout = Graph.layout(Kanban.graph(a.cwd), rank_edges: [proposed], force_ids: [a.id, b.id])
    positions = Map.new(layout.nodes, &{&1.card.id, &1})
    assert positions[a.id].x < positions[b.id].x
    assert layout.edges == []
    assert Kanban.graph(a.cwd).edges == []
  end

  test "worktree lanes keep ranks and put main first" do
    a = card("A", "feature")
    b = card("B")
    c = card("C", "feature")
    {:ok, _} = Kanban.add_dependency(b, a)
    {:ok, _} = Kanban.add_dependency(c, b)
    layout = Graph.layout(Kanban.graph(a.cwd), lanes: :worktree)
    assert Enum.map(layout.lanes, & &1.name) == ["main", "feature"]
    positions = Map.new(layout.nodes, &{&1.card.id, &1})
    assert positions[a.id].y == positions[c.id].y
    assert positions[b.id].y < positions[a.id].y
    assert positions[a.id].x < positions[b.id].x
    assert positions[b.id].x < positions[c.id].x
  end
end
