defmodule Jarvis2.Repo.Migrations.CreateRoleModels do
  use Ecto.Migration

  def change do
    create table(:role_models, primary_key: false) do
      add :role, :string, primary_key: true
      add :model, :string, null: false
    end
  end
end
