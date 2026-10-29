defmodule Jarvis2.Questions.Question do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "questions" do
    field :run_id, :binary_id
    field :kind, Ecto.Enum, values: [:question, :approval]
    field :prompt, :string
    field :detail, :string
    field :options, {:array, :string}, default: []

    field :status, Ecto.Enum,
      values: [:pending, :answered, :expired, :cancelled],
      default: :pending

    field :answer, :string
    field :answered_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(question, attrs) do
    question
    |> cast(attrs, [:run_id, :kind, :prompt, :detail, :options, :expires_at])
    |> validate_required([:run_id, :kind, :prompt, :expires_at])
    |> validate_length(:prompt, min: 1, max: 2_000, count: :bytes)
    |> validate_length(:detail, max: 2_000, count: :bytes)
    |> validate_length(:options, max: 10)
    |> validate_change(:options, fn :options, options ->
      if Enum.all?(options, &(byte_size(&1) in 1..100)),
        do: [],
        else: [options: "must be 1 to 100 bytes each"]
    end)
  end
end
