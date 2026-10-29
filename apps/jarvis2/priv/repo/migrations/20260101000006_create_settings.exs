defmodule Jarvis2.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    # A single row (id 1) holding everything the user can configure from the UI.
    create table(:settings, primary_key: false) do
      add :id, :integer, primary_key: true
      add :scenarios, {:array, :string}, null: false, default: []
      add :default_kind, :string, null: false
      add :default_model, :string, null: false
      add :default_thinking, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
