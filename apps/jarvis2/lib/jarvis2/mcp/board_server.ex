defmodule Jarvis2.MCP.BoardServer do
  @moduledoc false
  use Anubis.Server, name: "jarvis2-board", version: "0.1.0", capabilities: [:tools]

  alias Jarvis2.MCP.Server

  @impl true
  def init(_client, frame), do: {:ok, Server.register_board_tool(frame)}

  @impl true
  def handle_request(request, frame), do: Server.handle_request(request, frame, __MODULE__)

  @impl true
  def handle_tool_call(name, args, frame), do: Server.handle_tool_call(name, args, frame)
end
