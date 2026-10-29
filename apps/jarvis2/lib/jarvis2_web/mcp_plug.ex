defmodule Jarvis2Web.MCPPlug do
  @moduledoc """
  Guards the MCP endpoint: a bearer token is required and browser origins are refused, so a web
  page cannot drive the control plane through the user's browser.
  """
  @behaviour Plug
  import Plug.Conn

  @mcp Anubis.Server.Transport.StreamableHTTP.Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not authorized?(conn) ->
        error(conn, 401, "unauthorized")

      get_req_header(conn, "origin") != [] ->
        error(conn, 403, "browser origins are not supported")

      true ->
        @mcp.call(conn, @mcp.init(server: Jarvis2.MCP.Server, request_timeout: 120_000))
    end
  end

  # The long-lived file token (agents not started as runs) or a live per-run token.
  defp authorized?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer j2r_" <> _ = header] ->
        match?(
          {:ok, _},
          header |> String.replace_prefix("Bearer ", "") |> Jarvis2.Tokens.resolve()
        )

      ["Bearer " <> token] ->
        Plug.Crypto.secure_compare(token, Jarvis2.Token.get())

      _ ->
        false
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
