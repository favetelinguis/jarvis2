defmodule Jarvis2Web.KanbanLive.SkillUses do
  @moduledoc false
  use Phoenix.Component
  alias Jarvis2.Kanban.Kind

  attr :card, :map, required: true

  def skill_uses(assigns) do
    stages =
      Kind.stages(assigns.card.kind)
      |> Enum.map(& &1.name)
      |> Enum.filter(fn stage ->
        stage == assigns.card.stage or Enum.any?(assigns.card.skill_uses, &(&1.stage == stage))
      end)

    assigns = assign(assigns, :stages, stages)

    ~H"""
    <section :for={stage <- @stages} id={"skills-#{stage}"}>
      <h3>Skills — {stage |> Atom.to_string() |> String.capitalize()}</h3>
      <% uses = Enum.filter(@card.skill_uses, &(&1.stage == stage)) %>
      <p :if={uses == []}>No skills reported</p>
      <ul :if={uses != []}>
        <li :for={use <- uses}>{use.name} — {use.reason}</li>
      </ul>
    </section>
    """
  end
end
