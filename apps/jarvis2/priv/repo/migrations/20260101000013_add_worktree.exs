defmodule Jarvis2.Repo.Migrations.AddWorktree do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :worktree, :string, null: false, default: "main"
    end

    alter table(:runs) do
      add :worktree, :string, null: false, default: "main"
      add :workspace_id, :string
    end
  end
end
