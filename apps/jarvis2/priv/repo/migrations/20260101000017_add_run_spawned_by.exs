defmodule Jarvis2.Repo.Migrations.AddRunSpawnedBy do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :spawned_by_run_id, :binary_id
    end

    create index(:runs, [:spawned_by_run_id])
  end
end
