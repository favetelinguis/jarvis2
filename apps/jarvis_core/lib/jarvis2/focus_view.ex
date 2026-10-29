defmodule Jarvis2.FocusView do
  @moduledoc "The plugin’s transient agent view."
  @source "plugin:favetelinguis.jarvis2"
  @view %{
    source: @source,
    label: "focus",
    filter: %{
      op: "any",
      filters: [
        %{op: "eq", field: "workspace_id", value: %{context: "current_workspace_id"}},
        %{op: "in", field: "status", values: ["blocked", "done"]}
      ]
    },
    sort: [
      %{field: "attention", order: "desc"},
      %{field: "state_change_seq", order: "desc"}
    ]
  }

  def view, do: @view
end
