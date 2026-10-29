defmodule Jarvis2.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :kind, :string, null: false, default: "pi"
      add :model, :string, null: false
      add :thinking, :string, null: false
      add :cwd, :string, null: false
      add :task, :text, null: false
      add :status, :string, null: false, default: "starting"
      add :pane_id, :string
      # Pane ids can be reused; the terminal id proves a pane is still the one we created.
      add :terminal_id, :string
      add :agent_name, :string
      add :parent_run_id, :binary_id
      add :result, :map
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:status])
    create index(:runs, [:inserted_at])
  end
end
