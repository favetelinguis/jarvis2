defmodule Jarvis2.Repo.Migrations.AddCardKind do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :kind, :string, null: false, default: "plan"
    end

    rename table(:cards), :plan, to: :deliverable
  end
end
