defmodule Jarvis2.WorktreeMigrationTest do
  use ExUnit.Case, async: false

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :jarvis2, adapter: Ecto.Adapters.SQLite3
  end

  test "existing cards and runs default to main and retain their tab on rollback" do
    path =
      Path.join(
        System.tmp_dir!(),
        "jarvis2-worktree-migration-#{System.unique_integer([:positive])}.db"
      )

    start_supervised!({MigrationRepo, database: path, pool_size: 2})
    on_exit(fn -> File.rm(path) end)
    Ecto.Adapters.SQL.query!(MigrationRepo, "CREATE TABLE cards (id TEXT PRIMARY KEY)", [])

    Ecto.Adapters.SQL.query!(
      MigrationRepo,
      "CREATE TABLE runs (id TEXT PRIMARY KEY, tab_id TEXT)",
      []
    )

    Ecto.Adapters.SQL.query!(MigrationRepo, "INSERT INTO cards VALUES ('card')", [])
    Ecto.Adapters.SQL.query!(MigrationRepo, "INSERT INTO runs VALUES ('run', 'w1:t2')", [])
    version = 20_260_101_000_013
    migration = Jarvis2.Repo.Migrations.AddWorktree
    assert :ok = Ecto.Migrator.up(MigrationRepo, version, migration, log: false)

    assert %{rows: [["main"]]} =
             Ecto.Adapters.SQL.query!(MigrationRepo, "SELECT worktree FROM cards", [])

    assert %{rows: [["main", nil, "w1:t2"]]} =
             Ecto.Adapters.SQL.query!(
               MigrationRepo,
               "SELECT worktree, workspace_id, tab_id FROM runs",
               []
             )

    assert :ok = Ecto.Migrator.down(MigrationRepo, version, migration, log: false)

    assert %{rows: [["w1:t2"]]} =
             Ecto.Adapters.SQL.query!(MigrationRepo, "SELECT tab_id FROM runs", [])
  end
end
