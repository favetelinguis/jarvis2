import Config

if config_env() == :test do
  config :jarvis2,
    state_dir:
      Path.join(System.tmp_dir!(), "jarvis2-test-#{System.pid()}-#{System.os_time(:nanosecond)}"),
    serve: false,
    events: false,
    scenarios: false,
    live: false,
    allow_eval: false
else
  port =
    case Integer.parse(System.get_env("JARVIS2_PORT", "4747")) do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise "JARVIS2_PORT must be an integer between 1 and 65535"
    end

  config :jarvis2,
    port: port,
    state_dir:
      System.get_env("JARVIS2_STATE_DIR") ||
        Path.expand("~/.local/state/jarvis2"),
    serve: true,
    live: System.get_env("JARVIS2_LIVE") == "1",
    allow_eval: System.get_env("JARVIS2_ALLOW_EVAL") == "1",
    mix_project_dir: File.cwd!()
end
