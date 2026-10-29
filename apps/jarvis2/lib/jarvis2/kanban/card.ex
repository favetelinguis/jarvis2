defmodule Jarvis2.Kanban.Card do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias Jarvis2.Kanban.Kind

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "cards" do
    field :title, :string
    field :body, :string
    field :cwd, :string
    field :column, Ecto.Enum, values: [:scratch, :agent, :awaiting_user, :done], default: :scratch
    field :kind, Ecto.Enum, values: Kind.all(), default: :plan
    field :deliverable, :string
    belongs_to :run, Jarvis2.Runs.Run, type: :binary_id
    has_many :rounds, Jarvis2.Kanban.Round
    has_many :feedback, Jarvis2.Kanban.Feedback
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(card, attrs) do
    card
    |> cast(attrs, [:title, :body, :cwd, :kind])
    |> validate_required([:title, :cwd, :kind])
    |> validate_kind_unchanged()
    |> validate_length(:title, max: 120, count: :bytes)
    |> validate_body()
    |> Jarvis2.Runs.Run.validate_cwd()
  end

  defp validate_kind_unchanged(%{data: %{__meta__: %{state: :loaded}}} = changeset) do
    validate_change(changeset, :kind, fn :kind, _ -> [kind: "cannot be changed"] end)
  end

  defp validate_kind_unchanged(changeset), do: changeset

  defp validate_body(changeset) do
    kind = get_field(changeset, :kind) || :plan
    validate_length(changeset, :body, max: Kind.get(kind).max_body, count: :bytes)
  end
end
