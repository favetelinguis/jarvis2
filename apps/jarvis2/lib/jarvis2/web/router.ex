defmodule Jarvis2.Web.Router do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    json(conn, 200, %{status: "ok"})
  end

  get "/status" do
    mirror = Application.get_env(:jarvis2, :mirror, Jarvis2.Herdr.Mirror)
    view = Jarvis2.Herdr.Mirror.get(mirror)
    calls = Jarvis2.Journal.count(source: :mcp)

    status =
      case view do
        %{stale: false, snapshot: %{"agents" => agents}} ->
          blocked = Enum.count(agents, &(&1["agent_status"] == "blocked"))
          "◆ #{length(agents)} agents · #{blocked} blocked · #{calls} mcp calls\n"

        _ ->
          "◆ offline · #{calls} mcp calls\n"
      end

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, status)
  end

  match "/mcp" do
    cond do
      not authorized?(conn) ->
        json(conn, 401, %{error: "unauthorized"})

      get_req_header(conn, "origin") != [] ->
        json(conn, 403, %{error: "browser origins are not supported"})

      true ->
        plug = Anubis.Server.Transport.StreamableHTTP.Plug
        plug.call(conn, plug.init(server: Jarvis2.MCP.Server, request_timeout: 120_000))
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  defp authorized?(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Plug.Crypto.secure_compare(token, Jarvis2.Token.get())
      _ -> false
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
