import Config

# SDK protocol diagnostics can include client arguments and headers.
config :anubis_mcp, log: false

# Live requests require both JARVIS2_LIVE=1 and an explicitly enabled scenario.
config :jarvis2, live_scenarios: [], ecto_repos: [Jarvis2.Repo]
