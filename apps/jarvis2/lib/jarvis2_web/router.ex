defmodule Jarvis2Web.Router do
  use Jarvis2Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Jarvis2Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # The MCP endpoint reads its own request body, so no body parser may run before it.
  match :*, "/mcp", Jarvis2Web.MCPPlug, []

  get "/healthz", Jarvis2Web.StatusController, :healthz
  get "/status", Jarvis2Web.StatusController, :status

  scope "/", Jarvis2Web do
    pipe_through :browser

    get "/login", LoginController, :new
    post "/login", LoginController, :create
    delete "/logout", LoginController, :delete

    live_session :authenticated,
      on_mount: [{Jarvis2Web.Auth, :require_authenticated}, {Jarvis2Web.InboxCount, :default}] do
      live "/", DashboardLive
      live "/inbox", InboxLive
      live "/blackboard", BlackboardLive
      live "/events", EventLive
      live "/settings", SettingsLive
      live "/kanban", KanbanLive.Index, :index
      live "/kanban/cards/:id", KanbanLive.Index, :show
      live "/kanban/cards/:id/answer", KanbanLive.Index, :answer
      live "/kanban/cards/:id/reopen", KanbanLive.Index, :reopen
      live "/runs", RunLive.Index
      live "/runs/new", RunLive.New
      live "/runs/:id", RunLive.Show
    end
  end
end
