defmodule Jarvis2.Journal.Event do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "events" do
    field(:run_id, :binary_id)
    field(:source, Ecto.Enum, values: [:herdr, :mcp, :ui, :automation])
    field(:type, :string)
    field(:payload, :map, default: %{})
    field(:outcome, Ecto.Enum, values: [:ok, :error, :dry_run, :refused], default: :ok)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :source, :type, :payload, :outcome])
    |> validate_required([:source, :type])
    |> validate_length(:type, max: 128)
  end
end
