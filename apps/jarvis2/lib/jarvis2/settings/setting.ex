defmodule Jarvis2.Settings.Setting do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: false}
  schema "settings" do
    field :scenarios, {:array, :string}, default: []
    field :default_kind, :string, default: "pi"
    field :default_model, :string, default: "openrouter/openai/gpt-6-luna"
    field :default_thinking, :string, default: "low"

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(setting, attrs, known_scenarios) do
    setting
    |> cast(attrs, [:scenarios, :default_kind, :default_model, :default_thinking])
    |> validate_required([:default_kind, :default_model, :default_thinking])
    |> validate_subset(:scenarios, known_scenarios)
    |> validate_inclusion(:default_kind, Jarvis2.Herdr.Actions.agent_kinds())
    |> validate_inclusion(:default_thinking, Jarvis2.Runs.Run.thinking_levels())
    |> Jarvis2.Runs.Run.validate_model_field(:default_model)
    |> update_change(:scenarios, &Enum.uniq/1)
  end
end
