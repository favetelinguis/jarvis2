defmodule Jarvis2.Repo.Migrations.AddArrange do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :arrange_nudge_threshold, :integer, default: 3, null: false
    end

    alter table(:cards) do
      add :arrange_snapshot, :map
    end

    create unique_index(:cards, [:cwd],
             name: :cards_one_open_arrange_per_project,
             where: "kind = 'arrange' AND column != 'archive'"
           )
  end
end
