defmodule Jarvis2.Repo do
  use Ecto.Repo,
    otp_app: :jarvis2,
    adapter: Ecto.Adapters.SQLite3
end
