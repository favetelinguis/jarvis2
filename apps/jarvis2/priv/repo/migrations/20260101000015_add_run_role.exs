defmodule Jarvis2.Repo.Migrations.AddRunRole do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :role, :string
    end
  end
end
