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
    field :worktree, :string, default: "main"

    field :column, Ecto.Enum,
      values: [:scratch, :agent, :awaiting_user, :done, :archive],
      default: :scratch

    field :kind, Ecto.Enum, values: Kind.all(), default: :plan
    field :stage, Ecto.Enum, values: [:main, :planning, :implementation], default: :planning
    field :deliverable, :string
    field :accepted_plan, :string
    field :stage_started_at, :utc_datetime_usec
    field :arranged_at, :utc_datetime_usec
    field :arrange_snapshot, :map
    belongs_to :run, Jarvis2.Runs.Run, type: :binary_id
    has_many :rounds, Jarvis2.Kanban.Round
    has_many :feedback, Jarvis2.Kanban.Feedback
    has_many :skill_uses, Jarvis2.Kanban.SkillUse, preload_order: [asc: :id]
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(card, attrs) do
    card
    |> cast(attrs, [:title, :body, :cwd, :kind, :worktree])
    |> blank_worktree(attrs)
    |> update_change(:worktree, fn value ->
      if is_binary(value), do: String.trim(value), else: value
    end)
    |> validate_required([:title, :cwd, :kind, :worktree])
    |> validate_inclusion(:kind, Kind.creatable())
    |> validate_change(:worktree, fn :worktree, value ->
      if Jarvis2.Herdr.Workspaces.valid_worktree?(value), do: [], else: [worktree: "is invalid"]
    end)
    |> validate_worktree_unchanged()
    |> validate_kind_unchanged()
    |> initial_stage()
    |> validate_length(:title, max: 120, count: :bytes)
    |> validate_body()
    |> Jarvis2.Runs.Run.validate_cwd()
  end

  def arrange_changeset(cwd, snapshot) do
    %__MODULE__{}
    |> changeset(%{title: "Arrange dependencies", cwd: cwd})
    |> put_change(:kind, :arrange)
    |> put_change(:stage, :main)
    |> put_change(:arrange_snapshot, snapshot)
    |> unique_constraint(:cwd, name: :cards_one_open_arrange_per_project)
  end

  defp blank_worktree(changeset, attrs) do
    value = Map.get(attrs, :worktree, Map.get(attrs, "worktree"))

    if is_binary(value) and String.trim(value) == "",
      do: put_change(changeset, :worktree, nil),
      else: changeset
  end

  defp initial_stage(%{data: %{__meta__: %{state: :built}}} = changeset) do
    case get_field(changeset, :kind) do
      nil -> changeset
      kind -> put_change(changeset, :stage, Kind.initial_stage(kind))
    end
  end

  defp initial_stage(changeset), do: changeset

  defp validate_worktree_unchanged(%{data: %{__meta__: %{state: :loaded}}} = changeset) do
    validate_change(changeset, :worktree, fn :worktree, _ -> [worktree: "cannot be changed"] end)
  end

  defp validate_worktree_unchanged(changeset), do: changeset

  defp validate_kind_unchanged(%{data: %{__meta__: %{state: :loaded}}} = changeset) do
    validate_change(changeset, :kind, fn :kind, _ -> [kind: "cannot be changed"] end)
  end

  defp validate_kind_unchanged(changeset), do: changeset

  defp validate_body(changeset) do
    kind = get_field(changeset, :kind) || :plan
    validate_length(changeset, :body, max: Kind.get(kind).max_body, count: :bytes)
  end
end
