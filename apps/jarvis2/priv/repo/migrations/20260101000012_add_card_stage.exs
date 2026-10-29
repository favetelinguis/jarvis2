defmodule Jarvis2.Repo.Migrations.AddCardStage do
  use Ecto.Migration

  def up do
    alter table(:cards) do
      add :stage, :string, null: false, default: "main"
      add :accepted_plan, :text
      add :stage_started_at, :utc_datetime_usec
    end

    execute "UPDATE cards SET stage = 'planning' WHERE kind = 'plan'"
  end

  def down do
    alter table(:cards) do
      remove :stage_started_at
      remove :accepted_plan
      remove :stage
    end
  end
end
