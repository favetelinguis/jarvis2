defmodule Jarvis2Web.ConnCase do
  @moduledoc "Tests that drive the Phoenix endpoint, optionally with a signed-in session."
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint Jarvis2Web.Endpoint

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Jarvis2Web.ConnCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Jarvis2.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    %{conn: Phoenix.ConnTest.build_conn() |> Map.put(:host, "127.0.0.1")}
  end

  @doc "Signs in through the real login flow with a freshly issued single-use code."
  def sign_in(conn) do
    conn
    |> Phoenix.ConnTest.dispatch(
      Jarvis2Web.Endpoint,
      :get,
      "/login?code=" <> Jarvis2.LoginCodes.issue()
    )
    |> Phoenix.ConnTest.recycle()
  end
end
