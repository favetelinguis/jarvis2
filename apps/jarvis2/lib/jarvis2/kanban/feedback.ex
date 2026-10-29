defmodule Jarvis2.Kanban.Feedback do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "card_feedback" do
    field :card_id, :binary_id
    field :text, :string
    field :delivered_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(feedback, attrs) do
    feedback
    |> cast(attrs, [:card_id, :text])
    |> validate_required([:card_id, :text])
    |> validate_length(:text, max: 1_000, count: :bytes)
  end
end
