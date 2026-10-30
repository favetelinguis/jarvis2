defmodule Jarvis2.Repo.Migrations.CreateCardDependencies do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :arranged_at, :utc_datetime_usec
    end

    execute """
            CREATE TABLE card_dependencies (
              id TEXT PRIMARY KEY NOT NULL,
              card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
              blocked_by_card_id TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
              needs TEXT NOT NULL DEFAULT 'done',
              source TEXT NOT NULL,
              reason TEXT,
              inserted_at TEXT NOT NULL,
              CHECK (card_id != blocked_by_card_id)
            )
            """,
            "DROP TABLE card_dependencies"

    create unique_index(:card_dependencies, [:card_id, :blocked_by_card_id])
    create index(:card_dependencies, [:blocked_by_card_id])
  end
end
