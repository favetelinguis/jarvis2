defmodule Jarvis2.Repo.Migrations.CreateStepRoles do
  use Ecto.Migration

  def change do
    create table(:step_roles) do
      add :kind, :string, null: false
      add :stage, :string, null: false
      add :role, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:step_roles, [:kind, :stage])
  end
end
