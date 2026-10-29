defmodule Jarvis2.Repo.Migrations.CreateCards do
  use Ecto.Migration

  def change do
    create table(:cards, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :body, :text
      add :cwd, :text, null: false
      add :column, :string, null: false, default: "scratch"
      add :run_id, :binary_id
      add :plan, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:cards, [:column])
    create unique_index(:cards, [:run_id])

    create table(:card_rounds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :card_id, :binary_id, null: false
      add :number, :integer, null: false
      add :questions, {:array, :map}, null: false
      add :answers, :map, null: false, default: %{}
      add :status, :string, null: false, default: "open"
      add :delivered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:card_rounds, [:card_id, :status])
    create unique_index(:card_rounds, [:card_id, :number])

    create table(:card_feedback, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :card_id, :binary_id, null: false
      add :text, :text, null: false
      add :delivered_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
  end
end
