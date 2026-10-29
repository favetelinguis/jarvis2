defmodule Jarvis2.Repo.Migrations.DropApiTokens do
  use Ecto.Migration

  def up, do: drop(table(:api_tokens))

  def down do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, :binary_id
      add :token_hash, :string, null: false
      add :scope, :string, null: false, default: "run"
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:run_id])
  end
end
