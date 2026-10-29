defmodule Jarvis2.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    # Integer ids keep the append-only timeline strictly ordered and cheap to prune.
    create table(:events) do
      add :run_id, :binary_id
      add :source, :string, null: false
      add :type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :outcome, :string, null: false, default: "ok"

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:events, [:run_id, :inserted_at])
    create index(:events, [:inserted_at])
    create index(:events, [:source, :id])
  end
end
