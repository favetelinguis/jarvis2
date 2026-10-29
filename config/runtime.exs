import Config

if config_env() == :test do
  state_dir =
    Path.join(System.tmp_dir!(), "jarvis2-test-#{System.pid()}-#{System.os_time(:nanosecond)}")

  config :jarvis2,
    state_dir: state_dir,
    events: false,
    scenarios: false,
    live: false,
    allow_eval: false

  config :jarvis2, Jarvis2Web.Endpoint,
    secret_key_base: String.duplicate("jarvis2-test-secret-", 4)

  config :jarvis2, Jarvis2.Repo,
    database: Path.join(state_dir, "jarvis2.db"),
    pool: Ecto.Adapters.SQL.Sandbox,
    log: false,
    pool_size: 2
else
  port =
    case Integer.parse(System.get_env("JARVIS2_PORT", "4747")) do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise "JARVIS2_PORT must be an integer between 1 and 65535"
    end

  state_dir = System.get_env("JARVIS2_STATE_DIR") || Path.expand("~/.local/state/jarvis2")

  config :jarvis2,
    port: port,
    state_dir: state_dir,
    live: System.get_env("JARVIS2_LIVE") == "1",
    allow_eval: System.get_env("JARVIS2_ALLOW_EVAL") == "1",
    mix_project_dir: File.cwd!()

  config :jarvis2, Jarvis2.Repo, database: Path.join(state_dir, "jarvis2.db"), pool_size: 3

  # The cookie-signing secret lives next to the API token so it survives restarts.
  secret_file = Path.join(state_dir, "secret_key_base")
  File.mkdir_p!(state_dir)
  File.chmod!(state_dir, 0o700)

  secret_key_base =
    case File.read(secret_file) do
      {:ok, secret} when byte_size(secret) >= 64 ->
        String.trim(secret)

      _ ->
        secret = Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)
        File.write!(secret_file, secret)
        File.chmod!(secret_file, 0o600)
        secret
    end

  config :jarvis2, Jarvis2Web.Endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: port],
    url: [host: "127.0.0.1", port: port],
    check_origin: ["//127.0.0.1:#{port}", "//localhost:#{port}"],
    secret_key_base: secret_key_base
end
