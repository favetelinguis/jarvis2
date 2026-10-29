defmodule Jarvis2Web.Router do
  use Phoenix.Router

  forward("/", Jarvis2.Web.Router, [], log: false)
end
