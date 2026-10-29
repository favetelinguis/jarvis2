ExUnit.start()

ExUnit.after_suite(fn _ ->
  File.rm_rf!(Application.fetch_env!(:jarvis2, :state_dir))
end)
