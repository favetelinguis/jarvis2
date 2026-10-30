# Run through the extracted release's `eval`, with an isolated JARVIS2_STATE_DIR.
root = System.fetch_env!("RELEASE_ROOT")
version = System.fetch_env!("RELEASE_VSN")
true = version == System.fetch_env!("JARVIS2_VERSION")

share = Path.join(root, "share")
roles = Application.fetch_env!(:jarvis2, :roles_dir)
skills = Application.fetch_env!(:jarvis2, :skills_dir)
extension = Application.fetch_env!(:jarvis2, :pi_extension)
true = roles == Path.join(share, "roles")
true = skills == Path.join(share, "skills")
true = extension == Path.join(share, "jarvis2-run.js")
true = File.regular?(Path.join(roles, "planner.md"))
true = File.regular?(Path.join([skills, "tdd", "SKILL.md"]))
true = File.regular?(extension)

priv = :code.priv_dir(:jarvis2) |> to_string()
true = File.regular?(Path.join([priv, "static", "assets", "app.js"]))
true = File.regular?(Path.join([priv, "static", "assets", "app.css"]))

{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, _, _} = Ecto.Migrator.with_repo(Jarvis2.Repo, fn repo ->
  migrations = Path.join([priv, "repo", "migrations"])
  [_ | _] = Ecto.Migrator.run(repo, migrations, :up, all: true)
  %{rows: [[0]]} = Ecto.Adapters.SQL.query!(repo, "SELECT count(*) FROM cards", [])
end)

IO.puts("Release #{version} smoke check passed")
