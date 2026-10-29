defmodule Jarvis2Web.Router do
  use Jarvis2Web, :router

  # The MCP endpoint reads its own request body, so no body parser may run before it.
  match(:*, "/mcp", Jarvis2Web.MCPPlug, [])

  get("/healthz", Jarvis2Web.StatusController, :healthz)
  get("/status", Jarvis2Web.StatusController, :status)
end
