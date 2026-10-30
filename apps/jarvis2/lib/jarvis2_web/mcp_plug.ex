defmodule Jarvis2Web.MCPPlug do
  @moduledoc """
  Guards the MCP endpoint by refusing browser origins, so a web page cannot drive the control
  plane through the user's browser.
  """
  @behaviour Plug
  import Plug.Conn

  @mcp Anubis.Server.Transport.StreamableHTTP.Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    if get_req_header(conn, "origin") != [] do
      error(conn, 403, "browser origins are not supported")
    else
      @mcp.call(
        conn,
        @mcp.init(server: opts[:server] || Jarvis2.MCP.Server, request_timeout: 120_000)
      )
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
