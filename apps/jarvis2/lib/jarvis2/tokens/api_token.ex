defmodule Jarvis2.Tokens.ApiToken do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "api_tokens" do
    field :run_id, :binary_id
    field :token_hash, :string
    field :scope, Ecto.Enum, values: [:run, :ui], default: :run
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
