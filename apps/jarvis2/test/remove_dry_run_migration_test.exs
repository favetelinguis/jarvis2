defmodule Jarvis2.RemoveDryRunMigrationTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :jarvis2, adapter: Ecto.Adapters.SQLite3
  end

  test "legacy rows load with their replacement enum values" do
    path =
      Path.join(System.tmp_dir!(), "jarvis2-migration-#{System.unique_integer([:positive])}.db")

    start_supervised!({MigrationRepo, database: path, pool_size: 2})
    on_exit(fn -> File.rm(path) end)

    Ecto.Adapters.SQL.query!(MigrationRepo, "CREATE TABLE runs (status TEXT)", [])
    Ecto.Adapters.SQL.query!(MigrationRepo, "CREATE TABLE events (outcome TEXT)", [])

    Ecto.Adapters.SQL.query!(
      MigrationRepo,
      "INSERT INTO runs VALUES ('dry_run'), ('working')",
      []
    )

    Ecto.Adapters.SQL.query!(MigrationRepo, "INSERT INTO events VALUES ('dry_run'), ('ok')", [])

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               20_260_101_000_008,
               Jarvis2.Repo.Migrations.RemoveDryRun,
               log: false
             )

    assert Enum.sort(MigrationRepo.all(from r in Jarvis2.Runs.Run, select: r.status)) == [
             :stopped,
             :working
           ]

    assert Enum.sort(MigrationRepo.all(from e in Jarvis2.Journal.Event, select: e.outcome)) == [
             :ok,
             :refused
           ]
  end
end
