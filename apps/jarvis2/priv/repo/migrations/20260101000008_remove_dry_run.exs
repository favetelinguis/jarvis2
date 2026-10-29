defmodule Jarvis2.Repo.Migrations.RemoveDryRun do
  use Ecto.Migration

  # These historical entries did not execute a mutation; they cannot be recovered on rollback.
  def up do
    execute("UPDATE runs SET status = 'stopped' WHERE status = 'dry_run'")
    execute("UPDATE events SET outcome = 'refused' WHERE outcome = 'dry_run'")
  end

  def down, do: :ok
end
