defmodule Jarvis2.MCP do
  @moduledoc false

  def child_specs, do: [{Jarvis2.MCP.Server, transport: :streamable_http}]
end
