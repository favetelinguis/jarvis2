defmodule Jarvis2.RepoTest do
  use Jarvis2.DataCase, async: false

  test "opens the SQLite database inside the configured state directory" do
    assert Jarvis2.Repo.config()[:database] ==
             Path.join(Application.fetch_env!(:jarvis2, :state_dir), "jarvis2.db")

    assert %{rows: [[1]]} = Ecto.Adapters.SQL.query!(Jarvis2.Repo, "SELECT 1", [])
    assert %{rows: [["wal"]]} = Ecto.Adapters.SQL.query!(Jarvis2.Repo, "PRAGMA journal_mode", [])
    assert File.regular?(Jarvis2.Repo.config()[:database])
  end
end
