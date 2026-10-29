defmodule Jarvis2Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :jarvis2

  # Request logging is omitted on purpose: query strings may carry the one-time login token.
  plug(Plug.RequestId)
  plug(Jarvis2Web.Router)
end
