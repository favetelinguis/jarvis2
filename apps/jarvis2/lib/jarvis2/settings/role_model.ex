defmodule Jarvis2.Settings.RoleModel do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:role, :string, autogenerate: false}
  schema "role_models" do
    field :model, :string
  end
end
