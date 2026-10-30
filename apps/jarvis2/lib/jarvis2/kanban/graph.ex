defmodule Jarvis2.Kanban.Graph do
  @moduledoc "Pure layered layout for a project's dependency graph."

  @width 200
  @height 80
  @x_gap 100
  @y_gap 40
  @margin 40

  def layout(%{nodes: nodes, edges: edges}, opts \\ []) do
    connected =
      MapSet.new(
        Enum.flat_map(edges, &[&1.card_id, &1.blocked_by_card_id]) ++ (opts[:force_ids] || [])
      )

    {drawn, disconnected} = Enum.split_with(nodes, &MapSet.member?(connected, &1.id))

    prereqs =
      Enum.group_by(edges ++ (opts[:rank_edges] || []), & &1.card_id, & &1.blocked_by_card_id)

    ranks = Enum.reduce(drawn, %{}, fn card, acc -> elem(rank(card.id, prereqs, acc), 1) end)
    ordered = order(drawn, ranks, prereqs)

    lane_order =
      drawn
      |> Enum.map(& &1.worktree)
      |> Enum.uniq()
      |> Enum.sort_by(&if(&1 == "main", do: 0, else: 1))

    {positions, lanes, height} = positions(ordered, opts[:lanes], lane_order)
    by_id = Map.new(positions, &{&1.card.id, &1})

    paths =
      Enum.map(edges, fn edge ->
        from = by_id[edge.blocked_by_card_id]
        to = by_id[edge.card_id]
        Map.put(path(from, to), :edge, edge)
      end)

    max_rank = ranks |> Map.values() |> Enum.max(fn -> 0 end)

    %{
      nodes: positions,
      edges: paths,
      disconnected: disconnected,
      lanes: lanes,
      width: @margin * 2 + @width + max_rank * (@width + @x_gap),
      height: height
    }
  end

  def proposal_paths(layout, review) do
    positions = Map.new(layout.nodes, &{&1.card.id, &1})

    for item <- review.edges,
        from = positions[item.edge["blocked_by"]],
        to = positions[item.edge["card"]],
        from && to do
      Map.put(path(from, to), :proposal, item)
    end
  end

  defp path(from, to) do
    x1 = from.x + @width
    y1 = from.y + div(@height, 2)
    x2 = to.x
    y2 = to.y + div(@height, 2)
    midpoint = div(x1 + x2, 2)

    %{
      path: "M #{x1} #{y1} C #{midpoint} #{y1}, #{midpoint} #{y2}, #{x2} #{y2}",
      label_x: midpoint,
      label_y: div(y1 + y2, 2)
    }
  end

  def related(_edges, nil), do: MapSet.new()

  def related(edges, id) do
    upstream = walk([id], edges, :card_id, :blocked_by_card_id, MapSet.new())
    downstream = walk([id], edges, :blocked_by_card_id, :card_id, MapSet.new())
    MapSet.union(upstream, downstream)
  end

  defp walk([], _edges, _from, _to, seen), do: seen

  defp walk([id | rest], edges, from, to, seen) do
    if MapSet.member?(seen, id) do
      walk(rest, edges, from, to, seen)
    else
      next = for edge <- edges, Map.get(edge, from) == id, do: Map.get(edge, to)
      walk(next ++ rest, edges, from, to, MapSet.put(seen, id))
    end
  end

  defp rank(id, prereqs, memo) do
    case memo do
      %{^id => value} ->
        {value, memo}

      _ ->
        {values, memo} = Enum.map_reduce(Map.get(prereqs, id, []), memo, &rank(&1, prereqs, &2))
        value = if values == [], do: 0, else: 1 + Enum.max(values)
        {value, Map.put(memo, id, value)}
    end
  end

  defp order(nodes, ranks, prereqs) do
    nodes
    |> Enum.group_by(&Map.fetch!(ranks, &1.id))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({[], %{}}, fn {rank, cards}, {all, indices} ->
      cards = Enum.sort_by(cards, &order_key(&1, rank, prereqs, ranks, indices))

      indices =
        cards
        |> Enum.with_index()
        |> Enum.reduce(indices, fn {card, i}, map -> Map.put(map, card.id, i) end)

      {all ++ Enum.map(cards, &%{card: &1, rank: rank}), indices}
    end)
    |> elem(0)
  end

  defp order_key(card, rank, prereqs, ranks, indices) do
    predecessors = Map.get(prereqs, card.id, []) |> Enum.filter(&(ranks[&1] == rank - 1))

    barycentre =
      if predecessors == [],
        do: 0,
        else: Enum.sum(Enum.map(predecessors, &indices[&1])) / length(predecessors)

    {barycentre, card.inserted_at, card.id}
  end

  defp positions(ordered, :worktree, names) do
    {lanes, height} =
      Enum.map_reduce(names, @margin, fn name, y ->
        max_count =
          ordered
          |> Enum.filter(&(&1.card.worktree == name))
          |> Enum.frequencies_by(& &1.rank)
          |> Map.values()
          |> Enum.max(fn -> 1 end)

        lane = %{name: name, y: y}
        {lane, y + max_count * (@height + @y_gap) + @y_gap}
      end)

    lane_y = Map.new(lanes, &{&1.name, &1.y})

    {nodes, _} =
      Enum.map_reduce(ordered, %{}, fn node, counts ->
        key = {node.card.worktree, node.rank}
        index = Map.get(counts, key, 0)

        pos =
          Map.merge(node, %{
            x: @margin + node.rank * (@width + @x_gap),
            y: lane_y[node.card.worktree] + index * (@height + @y_gap)
          })

        {pos, Map.put(counts, key, index + 1)}
      end)

    {nodes, lanes, max(height, @height + @margin * 2)}
  end

  defp positions(ordered, _, _names) do
    {nodes, counts} =
      Enum.map_reduce(ordered, %{}, fn node, counts ->
        index = Map.get(counts, node.rank, 0)

        pos =
          Map.merge(node, %{
            x: @margin + node.rank * (@width + @x_gap),
            y: @margin + index * (@height + @y_gap)
          })

        {pos, Map.put(counts, node.rank, index + 1)}
      end)

    count = counts |> Map.values() |> Enum.max(fn -> 1 end)
    {nodes, [], @margin * 2 + count * @height + (count - 1) * @y_gap}
  end
end
