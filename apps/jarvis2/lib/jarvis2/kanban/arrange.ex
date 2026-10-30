defmodule Jarvis2.Kanban.Arrange do
  @moduledoc "Snapshots and reviews bounded, human-approved dependency proposals."
  import Ecto.Query

  alias Jarvis2.Repo
  alias Jarvis2.Kanban.{Card, Dependencies, Dependency}

  @pass_limit 50
  @edge_limit 200

  def snapshot(cwd) do
    graph = Dependencies.graph(cwd)
    nodes = Enum.reject(graph.nodes, &(&1.kind == :arrange))

    considered =
      nodes
      |> Enum.filter(&(&1.column == :scratch and is_nil(&1.arranged_at)))
      |> Enum.take(@pass_limit)

    ids = MapSet.new(considered, & &1.id)
    extra = Enum.reject(nodes, &MapSet.member?(ids, &1.id))
    cards = Enum.map(considered, &snapshot_card/1)

    cards =
      Enum.reduce_while(extra, cards, fn card, acc ->
        next = acc ++ [snapshot_card(card)]
        if byte_size(Jason.encode!(next)) <= 40_000, do: {:cont, next}, else: {:halt, acc}
      end)

    included = MapSet.new(cards, & &1.id)

    edges =
      for edge <- graph.edges,
          MapSet.member?(included, edge.card_id) and
            MapSet.member?(included, edge.blocked_by_card_id) do
        %{
          card: edge.card_id,
          blocked_by: edge.blocked_by_card_id,
          needs: edge.needs,
          source: edge.source
        }
      end

    %{"considered" => Enum.map(considered, & &1.id), "cards" => cards, "edges" => edges}
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp snapshot_card(card) do
    %{
      id: card.id,
      title: card.title,
      kind: card.kind,
      column: card.column,
      worktree: card.worktree,
      arranged: not is_nil(card.arranged_at),
      body: truncate(card.body || "", 300)
    }
  end

  defp truncate(text, limit) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn c, acc ->
      if byte_size(acc) + byte_size(c) <= limit, do: {:cont, acc <> c}, else: {:halt, acc}
    end)
  end

  def validate(content, snapshot) when is_map(snapshot) do
    with {:ok, %{"considered" => considered, "edges" => edges}} <- Jason.decode(content),
         true <- is_list(considered) and length(considered) <= @pass_limit,
         true <- Enum.uniq(considered) == considered,
         true <- Enum.all?(considered, &(&1 in snapshot["considered"])),
         true <- is_list(edges) and length(edges) <= @edge_limit,
         true <- Enum.all?(edges, &valid_edge?(&1, considered)) do
      :ok
    else
      _ ->
        {:error,
         "Invalid arrangement JSON: expected considered snapshot card IDs and up to #{@edge_limit} edges with card, blocked_by, needs and reason."}
    end
  end

  def validate(_, _), do: {:error, "Missing arrangement snapshot."}

  defp valid_edge?(
         %{"card" => card, "blocked_by" => blocked_by, "needs" => needs, "reason" => reason},
         considered
       ) do
    card in considered and match?({:ok, _}, Ecto.UUID.cast(card)) and
      match?({:ok, _}, Ecto.UUID.cast(blocked_by)) and
      needs in ["done", "plan"] and is_binary(reason) and String.trim(reason) != "" and
      byte_size(reason) <= 1_000
  end

  defp valid_edge?(_, _), do: false

  def review(%Card{kind: :arrange, column: :done} = arrange) do
    with :ok <- validate(arrange.deliverable, arrange.arrange_snapshot),
         {:ok, proposal} <- Jason.decode(arrange.deliverable) do
      graph = Dependencies.graph(arrange.cwd)

      {edges, _graph} =
        proposal["edges"]
        |> Enum.with_index()
        |> Enum.map_reduce(graph, fn {edge, index}, graph ->
          error = snapshot_error(edge, arrange.arrange_snapshot) || edge_error(edge, graph)
          item = %{index: index, edge: edge, error: error}
          {item, if(error, do: graph, else: put_proposal(graph, edge))}
        end)

      {:ok, %{considered: proposal["considered"], edges: edges}}
    end
  end

  def review(_), do: {:error, "Arrangement is not ready for review."}

  defp snapshot_error(edge, snapshot) do
    unless Enum.any?(snapshot["cards"], &(&1["id"] == edge["blocked_by"])) do
      "prerequisite is not in the arrangement snapshot"
    end
  end

  defp edge_error(edge, graph) do
    card = Enum.find(graph.nodes, &(&1.id == edge["card"]))
    prerequisite = Enum.find(graph.nodes, &(&1.id == edge["blocked_by"]))

    if is_nil(card) or is_nil(prerequisite),
      do: "card no longer exists in this project",
      else: current_edge_error(edge, graph, card, prerequisite)
  end

  defp current_edge_error(edge, graph, card, prerequisite) do
    cond do
      card.column != :scratch ->
        "dependent has started"

      card.id == prerequisite.id ->
        "a card cannot depend on itself"

      edge["needs"] == "plan" and prerequisite.kind != :plan ->
        "needs plan requires a Plan card"

      Enum.any?(
        graph.edges,
        &(&1.card_id == card.id and &1.blocked_by_card_id == prerequisite.id)
      ) ->
        "dependency already exists"

      prerequisite not in Dependencies.candidates(card, graph) ->
        "would create a cycle"

      true ->
        nil
    end
  end

  defp put_proposal(graph, edge) do
    proposed = %Dependency{card_id: edge["card"], blocked_by_card_id: edge["blocked_by"]}
    %{graph | edges: [proposed | graph.edges]}
  end

  # The caller holds the project graph lock and transaction.
  def apply!(arrange, selected) do
    arrange = Repo.get(Card, arrange.id)

    proposal = proposal!(arrange, selected)
    {applied, skipped} = apply_edges(proposal["edges"], selected, arrange.arrange_snapshot)
    now = DateTime.utc_now()

    Repo.update_all(
      from(c in Card,
        where: c.id in ^proposal["considered"] and c.cwd == ^arrange.cwd and c.column == :scratch
      ),
      set: [arranged_at: now, updated_at: now]
    )

    arrange |> Ecto.Changeset.change(column: :archive) |> Repo.update!()
    %{applied: applied, skipped: Enum.reverse(skipped)}
  end

  defp proposal!(arrange, selected) do
    unless arrange && arrange.kind == :arrange && arrange.column == :done,
      do: Repo.rollback("Arrangement is no longer awaiting review.")

    case validate(arrange.deliverable, arrange.arrange_snapshot) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    proposal = Jason.decode!(arrange.deliverable)

    validate_selection!(selected, length(proposal["edges"]))
    proposal
  end

  defp validate_selection!(selected, count) do
    valid =
      is_list(selected) and Enum.uniq(selected) == selected and
        Enum.all?(selected, &(is_integer(&1) and &1 >= 0 and &1 < count))

    unless valid, do: Repo.rollback("Invalid selection.")
  end

  defp apply_edges(edges, selected, snapshot) do
    edges
    |> Enum.with_index()
    |> Enum.filter(fn {_edge, index} -> index in selected end)
    |> Enum.reduce({0, []}, fn {edge, index}, {count, skipped} ->
      case insert_proposal(edge, snapshot) do
        {:ok, _} -> {count + 1, skipped}
        {:error, reason} -> {count, [%{index: index, reason: reason} | skipped]}
      end
    end)
  end

  defp insert_proposal(edge, snapshot) do
    case snapshot_error(edge, snapshot) do
      nil ->
        Dependencies.insert(edge["card"], edge["blocked_by"],
          needs: edge["needs"],
          source: :arranger,
          reason: edge["reason"]
        )

      reason ->
        {:error, reason}
    end
  end

  def reset!(cwd) do
    ids =
      from(c in Card,
        where: c.cwd == ^cwd and c.column == :scratch and c.kind != :arrange,
        select: c.id
      )

    Repo.delete_all(
      from(d in Dependency, where: d.card_id in subquery(ids) and d.source == :arranger)
    )

    Repo.update_all(from(c in Card, where: c.id in subquery(ids)),
      set: [arranged_at: nil, updated_at: DateTime.utc_now()]
    )
  end
end
