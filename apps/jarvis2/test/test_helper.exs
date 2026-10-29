ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Jarvis2.Repo, :manual)

ExUnit.after_suite(fn _ ->
  File.rm_rf!(Application.fetch_env!(:jarvis2, :state_dir))
end)
