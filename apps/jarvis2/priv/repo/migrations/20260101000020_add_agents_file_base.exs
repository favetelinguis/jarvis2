defmodule Jarvis2.Repo.Migrations.AddAgentsFileBase do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :agents_file_base, :map
    end
  end
end
