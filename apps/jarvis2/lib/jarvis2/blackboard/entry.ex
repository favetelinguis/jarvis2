defmodule Jarvis2.Blackboard.Entry do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "blackboard_entries" do
    field(:key, :string)
    field(:value, Jarvis2.JSONValue)
    field(:updated_by_run_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:key, :value, :updated_by_run_id])
    |> validate_required([:key])
    |> validate_length(:key, min: 1, max: 256)
    |> validate_change(:value, fn :value, value ->
      if byte_size(Jason.encode!(value)) <= 16_384, do: [], else: [value: "is too large"]
    end)
    |> unique_constraint(:key)
  end
end
