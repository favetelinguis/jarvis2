defmodule Jarvis2.MCP do
  @moduledoc false

  def child_specs do
    for server <- [Jarvis2.MCP.Server, Jarvis2.MCP.BoardServer] do
      {server, transport: {:streamable_http, start: true}}
    end
  end
end
