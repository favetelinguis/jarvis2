defmodule Jarvis2.StepRoles do
  @moduledoc "Persistent role assignments for kanban steps."
  import Ecto.Query
  alias Jarvis2.{Journal, Repo, Roles}
  alias Jarvis2.Kanban.Kind
  alias Jarvis2.StepRoles.StepRole

  defmodule StepRole do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    schema "step_roles" do
      field :kind, :string
      field :stage, :string
      field :role, :string
      timestamps(type: :utc_datetime_usec)
    end

    def changeset(row, attrs) do
      row
      |> cast(attrs, [:kind, :stage, :role])
      |> validate_required([:kind, :stage, :role])
      |> validate_step()
      |> unique_constraint([:kind, :stage])
    end

    defp validate_step(changeset) do
      if Jarvis2.StepRoles.valid_step?(get_field(changeset, :kind), get_field(changeset, :stage)),
        do: changeset,
        else: add_error(changeset, :stage, "is not a valid step")
    end
  end

  def steps, do: for(kind <- Kind.all(), stage <- Kind.stages(kind), do: {kind, stage.name})

  def valid_step?(kind, stage), do: not is_nil(find_step(kind, stage))

  defp find_step(kind, stage)
       when (is_binary(kind) or is_atom(kind)) and (is_binary(stage) or is_atom(stage)) do
    Enum.find(steps(), fn {k, s} ->
      to_string(k) == to_string(kind) and to_string(s) == to_string(stage)
    end)
  end

  defp find_step(_, _), do: nil

  def role_name(kind, stage) do
    case find_step(kind, stage) do
      nil ->
        nil

      {k, s} ->
        case Repo.get_by(StepRole, kind: to_string(k), stage: to_string(s)) do
          nil -> Kind.stage(k, s).role
          row -> row.role
        end
    end
  end

  def resolve(kind, stage) do
    case role_name(kind, stage) do
      nil -> {:error, "Invalid step."}
      name -> Roles.get(name)
    end
  end

  def assign(kind, stage, role) do
    case find_step(kind, stage) do
      nil -> {:error, "Invalid step."}
      {k, s} -> assign_step(k, s, role)
    end
  end

  defp assign_step(kind, stage, role) do
    default = Kind.stage(kind, stage).role
    kind = to_string(kind)
    stage = to_string(stage)

    result =
      if role in [nil, default] do
        Repo.delete_all(from r in StepRole, where: r.kind == ^kind and r.stage == ^stage)
        {:ok, default}
      else
        with {:ok, _} <- Roles.get(role),
             {:ok, _} <-
               Repo.insert(
                 StepRole.changeset(%StepRole{}, %{kind: kind, stage: stage, role: role}),
                 on_conflict: {:replace, [:role, :updated_at]},
                 conflict_target: [:kind, :stage]
               ) do
          {:ok, role}
        end
      end

    case result do
      {:ok, name} ->
        Journal.record(%{
          source: :ui,
          type: "roles.assigned",
          payload: %{kind: kind, stage: stage, role: name}
        })

        {:ok, name}

      error ->
        error
    end
  end
end
