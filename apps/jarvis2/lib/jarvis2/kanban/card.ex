defmodule Jarvis2.Kanban.Card do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cards" do
    field :title, :string
    field :body, :string
    field :cwd, :string
    field :column, Ecto.Enum, values: [:scratch, :agent, :awaiting_user, :done], default: :scratch
    field :plan, :string
    belongs_to :run, Jarvis2.Runs.Run, type: :binary_id
    has_many :rounds, Jarvis2.Kanban.Round
    has_many :feedback, Jarvis2.Kanban.Feedback
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(card, attrs) do
    card
    |> cast(attrs, [:title, :body, :cwd])
    |> validate_required([:title, :cwd])
    |> validate_length(:title, max: 120, count: :bytes)
    |> validate_length(:body, max: 2_000, count: :bytes)
    |> Jarvis2.Runs.Run.validate_cwd()
  end
end
