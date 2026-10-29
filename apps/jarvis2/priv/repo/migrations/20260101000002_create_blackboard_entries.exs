defmodule Jarvis2.Repo.Migrations.CreateBlackboardEntries do
  use Ecto.Migration

  def change do
    create table(:blackboard_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :value, :text
      add :updated_by_run_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:blackboard_entries, [:key])
  end
end
