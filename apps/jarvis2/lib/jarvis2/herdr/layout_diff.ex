defmodule Jarvis2.Herdr.LayoutDiff do
  @moduledoc false

  @max_entities 2_048
  @max_nested 4_096
  @max_changes 64
  @layout_fields [:workspace_id, :focused_pane_id, :zoomed, :area]
  @statuses [nil, "idle", "working", "blocked", "done", "unknown"]

  def project(snapshot, worktrees, errors) do
    with {:ok, workspaces} <- index(snapshot["workspaces"], "workspace_id", &workspace/1),
         {:ok, tabs} <- index(snapshot["tabs"], "tab_id", &tab/1),
         {:ok, panes} <- index(snapshot["panes"], "pane_id", &pane/1),
         {:ok, agents} <- index(snapshot["agents"], "pane_id", &agent/1),
         true <- bounded_layouts?(snapshot["layouts"]),
         {:ok, layouts} <- index(snapshot["layouts"], "tab_id", &layout/1),
         {:ok, focus} <- focus(snapshot),
         {:ok, worktrees} <- worktrees(worktrees),
         true <- is_map(errors) and map_size(errors) <= @max_entities do
      {:ok,
       %{
         workspaces: workspaces,
         tabs: tabs,
         panes: panes,
         agents: agents,
         layouts: layouts,
         focus: focus,
         worktrees: worktrees,
         errors: errors
       }}
    else
      _ -> {:error, :invalid_or_oversized}
    end
  end

  def between(old, new) do
    changes =
      entity_changes("workspace", old.workspaces, new.workspaces, ~w(label number worktree)) ++
        entity_changes("tab", old.tabs, new.tabs, ~w(workspace_id label number)) ++
        entity_changes("pane", old.panes, new.panes, ~w(workspace_id tab_id terminal_id label)) ++
        entity_changes(
          "agent",
          old.agents,
          new.agents,
          ~w(workspace_id tab_id agent name agent_status)
        ) ++
        focus_changes(old.focus, new.focus) ++
        layout_changes(old.layouts, new.layouts) ++
        worktree_changes(old, new)

    {Enum.take(changes, @max_changes), length(changes) > @max_changes}
  end

  defp index(items, key, project) when is_list(items) and length(items) <= @max_entities do
    Enum.reduce_while(items, {:ok, %{}}, fn item, {:ok, acc} ->
      with true <- is_map(item),
           id when is_binary(id) <- item[key],
           true <- valid_id?(id),
           false <- Map.has_key?(acc, id),
           {:ok, value} <- project.(item) do
        {:cont, {:ok, Map.put(acc, id, value)}}
      else
        _ -> {:halt, {:error, :invalid_item}}
      end
    end)
  end

  defp index(_, _, _), do: {:error, :invalid_items}

  defp workspace(item), do: {:ok, Map.take(item, ~w(label number worktree))}
  defp tab(item), do: parent_fields(item, ~w(workspace_id), ~w(workspace_id label number))

  defp pane(item),
    do: parent_fields(item, ~w(workspace_id tab_id), ~w(workspace_id tab_id terminal_id label))

  defp agent(item) do
    if item["agent_status"] in @statuses do
      parent_fields(
        item,
        ~w(workspace_id tab_id),
        ~w(workspace_id tab_id agent name agent_status)
      )
    else
      {:error, :invalid_status}
    end
  end

  defp parent_fields(item, parents, fields) do
    if Enum.all?(parents, &valid_optional_id?(item[&1])) and
         valid_optional_id?(item["terminal_id"]) do
      {:ok, Map.take(item, fields)}
    else
      {:error, :invalid_parent}
    end
  end

  defp layout(item) do
    with true <- valid_optional_id?(item["workspace_id"]),
         true <- valid_optional_id?(item["focused_pane_id"]),
         true <- is_nil(item["zoomed"]) or is_boolean(item["zoomed"]),
         true <- not Map.has_key?(item, "area") or is_map(item["area"]),
         {:ok, area} <- rect(item["area"]),
         {:ok, panes} <- index(Map.get(item, "panes", []), "pane_id", &geometry/1),
         {:ok, splits} <- index(Map.get(item, "splits", []), "id", &split/1) do
      {:ok,
       %{
         workspace_id: item["workspace_id"],
         focused_pane_id: item["focused_pane_id"],
         zoomed: item["zoomed"],
         area: area,
         panes: panes,
         splits: splits
       }}
    else
      _ -> {:error, :invalid_layout}
    end
  end

  defp geometry(%{"rect" => rect}) when is_map(rect), do: rect(rect)
  defp geometry(_), do: {:error, :invalid_rect}

  defp split(item) do
    ratio = item["ratio"]

    with true <- item["direction"] in ["right", "down"],
         true <- is_number(ratio) and ratio >= 0 and ratio <= 1,
         true <- is_map(item["rect"]),
         {:ok, rect} <- rect(item["rect"]) do
      {:ok, %{direction: item["direction"], ratio: ratio, rect: rect}}
    else
      _ -> {:error, :invalid_split}
    end
  end

  defp rect(nil), do: {:ok, nil}

  defp rect(%{"x" => x, "y" => y, "width" => width, "height" => height}) do
    if Enum.all?([x, y, width, height], &(is_integer(&1) and &1 in 0..65_535)),
      do: {:ok, %{x: x, y: y, width: width, height: height}},
      else: {:error, :invalid_rect}
  end

  defp rect(_), do: {:error, :invalid_rect}

  defp focus(snapshot) do
    values = [
      snapshot["focused_workspace_id"],
      snapshot["focused_tab_id"],
      snapshot["focused_pane_id"]
    ]

    if Enum.all?(values, &valid_optional_id?/1) do
      [workspace, tab, pane] = values
      {:ok, %{workspace_id: workspace, tab_id: tab, pane_id: pane}}
    else
      {:error, :invalid_focus}
    end
  end

  defp bounded_layouts?(layouts) when is_list(layouts) and length(layouts) <= @max_entities do
    Enum.reduce_while(layouts, 0, fn layout, count ->
      panes = if is_map(layout), do: Map.get(layout, "panes", []), else: nil
      splits = if is_map(layout), do: Map.get(layout, "splits", []), else: nil

      if is_list(panes) and is_list(splits) do
        total = count + length(panes) + length(splits)
        if total <= @max_nested, do: {:cont, total}, else: {:halt, false}
      else
        {:halt, false}
      end
    end) != false
  end

  defp bounded_layouts?(_), do: false

  defp worktrees(trees) when is_map(trees) and map_size(trees) <= @max_entities do
    Enum.reduce_while(trees, {:ok, %{}, 0}, fn {key, items}, {:ok, acc, total} ->
      if is_binary(key) and is_list(items) and length(items) <= @max_entities and
           total + length(items) <= @max_nested do
        {:cont, {:ok, Map.put(acc, key, Enum.sort(items)), total + length(items)}}
      else
        {:halt, {:error, :invalid_worktrees}}
      end
    end)
    |> case do
      {:ok, value, _} -> {:ok, value}
      error -> error
    end
  end

  defp worktrees(_), do: {:error, :invalid_worktrees}

  defp valid_optional_id?(nil), do: true
  defp valid_optional_id?(id), do: valid_id?(id)

  defp valid_id?(id) when is_binary(id) and byte_size(id) in 1..128 do
    String.valid?(id) and not String.match?(id, ~r/[\p{C}]/u)
  end

  defp valid_id?(_), do: false

  defp entity_changes(kind, old, new, fields) do
    keys(old, new)
    |> Enum.flat_map(fn id ->
      before = old[id]
      after_value = new[id]
      change = change(before, after_value)

      changed_fields =
        if change == "updated",
          do: Enum.filter(fields, &(before[&1] != after_value[&1])),
          else: []

      if change == nil or (change == "updated" and changed_fields == []) do
        []
      else
        detail = %{kind: kind, id: id, change: change, fields: changed_fields}

        detail =
          if kind in ["tab", "pane", "agent"],
            do:
              Map.merge(detail, %{
                before: entity_view(kind, before),
                after: entity_view(kind, after_value)
              }),
            else: detail

        [detail]
      end
    end)
  end

  defp entity_view(_, nil), do: nil
  defp entity_view("tab", item), do: %{workspace_id: item["workspace_id"]}

  defp entity_view("pane", item),
    do: %{workspace_id: item["workspace_id"], tab_id: item["tab_id"]}

  defp entity_view("agent", item),
    do: %{
      workspace_id: item["workspace_id"],
      tab_id: item["tab_id"],
      status: item["agent_status"]
    }

  defp focus_changes(before, after_value) when before != after_value,
    do: [%{kind: "focus", before: before, after: after_value}]

  defp focus_changes(_, _), do: []

  defp layout_changes(old, new) do
    keys(old, new)
    |> Enum.flat_map(fn tab ->
      before = old[tab]
      after_value = new[tab]
      before_info = layout_info(before)
      after_info = layout_info(after_value)

      fields =
        if before_info && after_info do
          @layout_fields
          |> Enum.filter(&(before_info[&1] != after_info[&1]))
          |> Enum.map(&Atom.to_string/1)
        else
          []
        end

      summary =
        if before_info != after_info,
          do: [
            %{
              kind: "layout",
              id: tab,
              change: change(before_info, after_info),
              fields: fields,
              before: before_info,
              after: after_info
            }
          ],
          else: []

      panes_before = if before, do: before.panes, else: %{}
      panes_after = if after_value, do: after_value.panes, else: %{}
      splits_before = if before, do: before.splits, else: %{}
      splits_after = if after_value, do: after_value.splits, else: %{}

      summary ++
        child_changes("geometry", tab, panes_before, panes_after) ++
        child_changes("split", tab, splits_before, splits_after)
    end)
  end

  defp layout_info(nil), do: nil

  defp layout_info(layout),
    do: Map.take(layout, [:workspace_id, :focused_pane_id, :zoomed, :area])

  defp child_changes(kind, tab, old, new) do
    keys(old, new)
    |> Enum.flat_map(fn id ->
      before = old[id]
      after_value = new[id]

      if before != after_value do
        detail = %{
          kind: kind,
          tab_id: tab,
          change: change(before, after_value),
          before: before,
          after: after_value
        }

        [Map.put(detail, if(kind == "geometry", do: :pane_id, else: :id), id)]
      else
        []
      end
    end)
  end

  defp worktree_changes(old, new) do
    trees =
      if old.worktrees != new.worktrees,
        do: [
          %{
            kind: "worktrees",
            change: "updated",
            before: tree_counts(old.worktrees),
            after: tree_counts(new.worktrees)
          }
        ],
        else: []

    errors =
      if old.errors != new.errors,
        do: [
          %{
            kind: "worktree_availability",
            change: "updated",
            before: map_size(old.errors),
            after: map_size(new.errors)
          }
        ],
        else: []

    trees ++ errors
  end

  defp tree_counts(trees),
    do: %{
      repos: map_size(trees),
      worktrees: Enum.sum(Enum.map(trees, fn {_, values} -> length(values) end))
    }

  defp keys(old, new), do: (Map.keys(old) ++ Map.keys(new)) |> Enum.uniq() |> Enum.sort()
  defp change(nil, nil), do: nil
  defp change(nil, _), do: "added"
  defp change(_, nil), do: "removed"
  defp change(before, after_value) when before != after_value, do: "updated"
  defp change(_, _), do: nil
end
