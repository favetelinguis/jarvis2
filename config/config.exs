import Config

# SDK protocol diagnostics can include client arguments and headers.
config :anubis_mcp, log: false

# Live requests require both JARVIS2_LIVE=1 and an explicitly enabled scenario.
config :jarvis2, live_scenarios: [], ecto_repos: [Jarvis2.Repo]

config :jarvis2, Jarvis2Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: false,
  pubsub_server: Jarvis2.PubSub,
  live_view: [signing_salt: "jarvis2-live-view"],
  render_errors: [
    formats: [json: Jarvis2Web.ErrorJSON, html: Jarvis2Web.ErrorHTML],
    layout: false
  ]

config :phoenix, :json_library, Jason
