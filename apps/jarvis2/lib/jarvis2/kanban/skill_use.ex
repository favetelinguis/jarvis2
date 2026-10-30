defmodule Jarvis2.Kanban.SkillUse do
  @moduledoc false
  use Ecto.Schema

  schema "card_skill_uses" do
    belongs_to :card, Jarvis2.Kanban.Card, type: :binary_id
    belongs_to :run, Jarvis2.Runs.Run, type: :binary_id
    field :stage, Ecto.Enum, values: [:main, :planning, :implementation]
    field :name, :string
    field :reason, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
