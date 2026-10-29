defmodule Jarvis2.Repo.Migrations.AddRunSessionAndTab do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :session_id, :string
      add :tab_id, :string
    end
  end
end
