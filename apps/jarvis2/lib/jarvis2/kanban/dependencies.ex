defmodule Jarvis2.Kanban.Dependencies do
  @moduledoc "Dependency validation and readiness for cards in one project."
  import Ecto.Query, except: [lock: 2]

  alias Jarvis2.Repo
  alias Jarvis2.Kanban.{Card, Dependency}

  # Serialise graph edits and starts in this node, including the read/check/write sequence.
  def lock(cwd, fun), do: :global.trans({{__MODULE__, cwd}, self()}, fun)

  def add(%Card{} = card, %Card{} = prerequisite, opts) do
    lock(card.cwd, fn -> Repo.transaction(fn -> add!(card, prerequisite, opts) end) end)
  end

  # Called with the project lock and a transaction already held.
  def add!(%Card{} = card, %Card{} = prerequisite, opts) do
    case insert(card.id, prerequisite.id, opts) do
      {:ok, edge} -> edge
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Used by arrangement acceptance inside the same project lock and transaction.
  def insert(card_id, prerequisite_id, opts) do
    card = Repo.get(Card, card_id)
    prerequisite = Repo.get(Card, prerequisite_id)
    needs = normalize(Keyword.get(opts, :needs, :done), [:done, :plan])
    source = normalize(Keyword.get(opts, :source, :human), [:human, :harness, :arranger])

    with :ok <- validate_cards(card, prerequisite),
         :ok <- validate_options(prerequisite, needs, source),
         :ok <- validate_edge(card, prerequisite) do
      attrs = %{
        card_id: card.id,
        blocked_by_card_id: prerequisite.id,
        needs: needs,
        source: source,
        reason: opts[:reason]
      }

      case %Dependency{} |> Dependency.changeset(attrs) |> Repo.insert() do
        {:ok, edge} -> {:ok, edge}
        {:error, _} -> {:error, "invalid dependency"}
      end
    end
  end

  defp validate_cards(card, prerequisite) do
    cond do
      is_nil(card) or is_nil(prerequisite) ->
        {:error, "card not found"}

      card.cwd != prerequisite.cwd ->
        {:error, "cards must belong to the same project"}

      card.kind == :arrange or prerequisite.kind == :arrange ->
        {:error, "arrangements cannot have dependencies"}

      card.column != :scratch ->
        {:error, "dependencies are frozen once a card starts"}

      card.id == prerequisite.id ->
        {:error, "a card cannot depend on itself"}

      true ->
        :ok
    end
  end

  defp validate_options(prerequisite, needs, source) do
    cond do
      is_nil(needs) -> {:error, "invalid needs"}
      is_nil(source) -> {:error, "invalid source"}
      needs == :plan and prerequisite.kind != :plan -> {:error, "needs plan requires a Plan card"}
      true -> :ok
    end
  end

  defp validate_edge(card, prerequisite) do
    cond do
      Repo.get_by(Dependency, card_id: card.id, blocked_by_card_id: prerequisite.id) ->
        {:error, "dependency already exists"}

      path = cycle_path(card, prerequisite) ->
        {:error, "would create a cycle: " <> path}

      true ->
        :ok
    end
  end

  def remove(%Card{} = card, %Card{} = prerequisite, opts \\ []) do
    lock(card.cwd, fn -> Repo.transaction(fn -> remove!(card, prerequisite, opts) end) end)
  end

  defp remove!(card, prerequisite, opts) do
    current = Repo.get(Card, card.id)
    edge = Repo.get_by(Dependency, card_id: card.id, blocked_by_card_id: prerequisite.id)

    cond do
      is_nil(current) ->
        Repo.rollback("card not found")

      current.column != :scratch ->
        Repo.rollback("dependencies are frozen once a card starts")

      is_nil(edge) ->
        Repo.rollback("dependency not found")

      opts[:source] && edge.source != opts[:source] ->
        Repo.rollback("cannot remove this dependency")

      true ->
        Repo.delete!(edge)
    end
  end

  def edges(%Card{id: id}) do
    Dependency
    |> where([d], d.card_id == ^id)
    |> order_by([d], asc: d.inserted_at, asc: d.id)
    |> Repo.all()
    |> Repo.preload(:blocked_by_card)
  end

  def satisfied?(%Dependency{blocked_by_card: %Card{column: :archive}}), do: false
  def satisfied?(%Dependency{blocked_by_card: %Card{run_id: nil}}), do: false

  def satisfied?(%Dependency{needs: :plan, blocked_by_card: card}),
    do: is_binary(card.accepted_plan) and card.accepted_plan != ""

  def satisfied?(%Dependency{
        needs: :done,
        blocked_by_card: %Card{column: :done, kind: :plan, stage: :implementation}
      }),
      do: true

  def satisfied?(%Dependency{needs: :done, blocked_by_card: %Card{column: :done, kind: kind}})
      when kind != :plan, do: true

  def satisfied?(_), do: false

  def blockers(card), do: Enum.reject(edges(card), &satisfied?/1)

  def state(%Card{id: id}) do
    case Repo.get(Card, id) do
      nil -> {:none, []}
      card -> state_for(card, edges(card))
    end
  end

  def state_for(card, edges) do
    unsatisfied = Enum.reject(edges, &satisfied?/1)

    state =
      cond do
        edges == [] -> :none
        card.column == :scratch and unsatisfied != [] -> :blocked
        card.column == :scratch -> :ready
        card.column == :archive and is_nil(card.run_id) -> :none
        unsatisfied != [] -> :stale
        true -> :none
      end

    {state, unsatisfied}
  end

  def graph(cwd) do
    nodes =
      Repo.all(from c in Card, where: c.cwd == ^cwd, order_by: [asc: c.inserted_at, asc: c.id])

    edges =
      Repo.all(
        from d in Dependency,
          join: c in Card,
          on: c.id == d.card_id,
          where: c.cwd == ^cwd,
          order_by: [asc: d.inserted_at, asc: d.id]
      )

    by_id = Map.new(nodes, &{&1.id, &1})

    %{
      nodes: nodes,
      edges:
        Enum.map(
          edges,
          &%{&1 | card: by_id[&1.card_id], blocked_by_card: by_id[&1.blocked_by_card_id]}
        )
    }
  end

  def candidates(%Card{} = card, %{nodes: nodes, edges: edges}) do
    existing = MapSet.new(for edge <- edges, edge.card_id == card.id, do: edge.blocked_by_card_id)

    Enum.filter(nodes, fn node ->
      node.kind != :arrange and node.id != card.id and not MapSet.member?(existing, node.id) and
        not reaches?(node.id, card.id, edges, MapSet.new())
    end)
  end

  defp reaches?(id, target, _edges, _seen) when id == target, do: true

  defp reaches?(id, target, edges, seen) do
    if MapSet.member?(seen, id) do
      false
    else
      seen = MapSet.put(seen, id)

      Enum.any?(edges, fn edge ->
        edge.card_id == id and reaches?(edge.blocked_by_card_id, target, edges, seen)
      end)
    end
  end

  def ready(cwd) do
    %{nodes: nodes, edges: edges} = graph(cwd)
    blocked_ids = edges |> Enum.reject(&satisfied?/1) |> MapSet.new(& &1.card_id)

    Enum.filter(
      nodes,
      &(&1.kind != :arrange and &1.column == :scratch and not MapSet.member?(blocked_ids, &1.id))
    )
  end

  defp normalize(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp normalize(value, allowed) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  defp normalize(_, _), do: nil

  defp cycle_path(card, prerequisite) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        WITH RECURSIVE reach(id) AS (
          SELECT ?
          UNION
          SELECT d.blocked_by_card_id
          FROM card_dependencies d JOIN reach ON d.card_id = reach.id
        )
        SELECT id FROM reach WHERE id = ? LIMIT 1
        """,
        [prerequisite.id, card.id]
      )

    case result.rows do
      [] ->
        nil

      _ ->
        graph = graph(card.cwd)
        adjacent = Enum.group_by(graph.edges, & &1.card_id, & &1.blocked_by_card_id)
        titles = Map.new(graph.nodes, &{&1.id, &1.title})
        ids = find_path([[prerequisite.id]], card.id, adjacent, MapSet.new())
        Enum.map_join([card.id | ids], " → ", &Map.get(titles, &1, &1))
    end
  end

  defp find_path([[target | _] = path | _], target, _adjacent, _seen), do: Enum.reverse(path)

  defp find_path([[id | _] = path | rest], target, adjacent, seen) do
    if MapSet.member?(seen, id) do
      find_path(rest, target, adjacent, seen)
    else
      next = Enum.map(Map.get(adjacent, id, []), &[&1 | path])
      find_path(rest ++ next, target, adjacent, MapSet.put(seen, id))
    end
  end
end
