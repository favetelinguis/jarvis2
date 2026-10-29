defmodule Jarvis2Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :jarvis2

  plug(Jarvis2Web.Router)
end
