defmodule Jarvis2.Kanban.Dependency do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "card_dependencies" do
    belongs_to :card, Jarvis2.Kanban.Card, type: :binary_id
    belongs_to :blocked_by_card, Jarvis2.Kanban.Card, type: :binary_id
    field :needs, Ecto.Enum, values: [:done, :plan], default: :done
    field :source, Ecto.Enum, values: [:human, :harness, :arranger], default: :human
    field :reason, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:card_id, :blocked_by_card_id, :needs, :source, :reason])
    |> validate_required([:card_id, :blocked_by_card_id, :needs, :source])
    |> unique_constraint([:card_id, :blocked_by_card_id])
    |> foreign_key_constraint(:card_id)
    |> foreign_key_constraint(:blocked_by_card_id)
  end
end
