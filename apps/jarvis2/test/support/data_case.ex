defmodule Jarvis2.DataCase do
  @moduledoc "Runs a test with exclusive, rolled-back access to the database."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Jarvis2.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Jarvis2.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
