defmodule Jarvis2.Repo.Migrations.CreateQuestions do
  use Ecto.Migration

  def change do
    create table(:questions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, :binary_id, null: false
      add :kind, :string, null: false
      add :prompt, :text, null: false
      add :detail, :text
      add :options, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "pending"
      add :answer, :text
      add :answered_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:questions, [:status, :inserted_at])
    create index(:questions, [:run_id, :status])
  end
end
