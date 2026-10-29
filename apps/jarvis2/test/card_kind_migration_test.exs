defmodule Jarvis2.CardKindMigrationTest do
  use ExUnit.Case, async: false

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :jarvis2, adapter: Ecto.Adapters.SQLite3
  end

  test "existing plans survive the migration and rollback" do
    path =
      Path.join(
        System.tmp_dir!(),
        "jarvis2-card-migration-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!({MigrationRepo, database: path, pool_size: 2})
    on_exit(fn -> File.rm(path) end)

    Ecto.Adapters.SQL.query!(
      MigrationRepo,
      "CREATE TABLE cards (id TEXT PRIMARY KEY, plan TEXT)",
      []
    )

    Ecto.Adapters.SQL.query!(MigrationRepo, "INSERT INTO cards VALUES ('old', 'old plan')", [])
    version = 20_260_101_000_010
    migration = Jarvis2.Repo.Migrations.AddCardKind
    assert :ok = Ecto.Migrator.up(MigrationRepo, version, migration, log: false)

    assert %{rows: [["plan", "old plan"]]} =
             Ecto.Adapters.SQL.query!(MigrationRepo, "SELECT kind, deliverable FROM cards", [])

    assert :ok = Ecto.Migrator.down(MigrationRepo, version, migration, log: false)

    assert %{rows: [["old plan"]]} =
             Ecto.Adapters.SQL.query!(MigrationRepo, "SELECT plan FROM cards", [])
  end
end
