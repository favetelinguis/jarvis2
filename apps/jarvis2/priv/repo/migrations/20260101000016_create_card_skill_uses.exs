defmodule Jarvis2.Repo.Migrations.CreateCardSkillUses do
  use Ecto.Migration

  def change do
    create table(:card_skill_uses) do
      add :card_id, :binary_id, null: false
      add :run_id, :binary_id, null: false
      add :stage, :string, null: false
      add :name, :text, null: false
      add :reason, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:card_skill_uses, [:card_id])
  end
end
