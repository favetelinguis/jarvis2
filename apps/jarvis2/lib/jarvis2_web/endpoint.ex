defmodule Jarvis2Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :jarvis2

  @session_options [
    store: :cookie,
    key: "_jarvis2_key",
    signing_salt: "jarvis2-session",
    same_site: "Lax",
    max_age: 7 * 24 * 3600
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # Request logging is omitted on purpose: query strings may carry a sign-in code.
  plug Jarvis2Web.HostCheck

  # The Phoenix and LiveView client bundles come straight from their packages.
  plug Plug.Static, at: "/vendor", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/vendor",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.Static,
    at: "/assets",
    from: {:jarvis2, "priv/static/assets"},
    only: ~w(app.js app.css)

  plug Plug.RequestId
  plug Plug.Session, @session_options
  plug Jarvis2Web.Router
end
