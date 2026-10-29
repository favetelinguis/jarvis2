defmodule Jarvis2.Web.Router do
  @moduledoc false
  use Plug.Router
  @body_limit 65_536

  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    json(conn, 200, %{status: "ok"})
  end

  get "/status" do
    mirror = Application.get_env(:jarvis2, :mirror, Jarvis2.Herdr.Mirror)
    view = Jarvis2.Herdr.Mirror.get(mirror)
    calls = Jarvis2.State.mcp_call_count()

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

  get "/dashboard" do
    cond do
      not authorized?(conn) ->
        json(conn, 401, %{error: "unauthorized"})

      get_req_header(conn, "origin") != [] ->
        json(conn, 403, %{error: "browser origins are not supported"})

      true ->
        mirror = Application.get_env(:jarvis2, :mirror, Jarvis2.Herdr.Mirror)
        view = Jarvis2.Herdr.Mirror.get(mirror)

        agents =
          case view.snapshot do
            %{"agents" => agents} when is_list(agents) ->
              agents
              |> Enum.filter(&is_map/1)
              |> Enum.take(100)
              |> Enum.map(&Map.take(&1, ~w(pane_id name agent agent_status)))

            _ ->
              []
          end

        events =
          Jarvis2.State.events()
          |> Enum.take(-20)
          |> Enum.map(&Map.take(&1, [:delivery, :type, :kind, :id]))

        journal =
          Jarvis2.State.recent_journal()
          |> Enum.take(-20)
          |> Enum.map(fn entry ->
            caller = if is_map(entry[:caller]), do: entry[:caller], else: %{}

            %{
              tool: entry[:tool],
              outcome: entry[:outcome],
              timestamp: entry[:timestamp],
              pane: caller[:pane]
            }
          end)

        json(conn, 200, %{stale: view.stale, agents: agents, events: events, journal: journal})
    end
  end

  post "/hook/:kind/:id" do
    if authorized?(conn) do
      case read_json(conn) do
        {:ok, body, conn} when is_map(body) ->
          :ok = Jarvis2.Web.Hooks.accept(kind, id, body)
          json(conn, 202, %{status: "accepted"})

        {:ok, _, conn} ->
          json(conn, 400, %{error: "JSON body must be an object"})

        {:error, status, conn} ->
          json(conn, status, %{error: "invalid or oversized JSON body"})
      end
    else
      json(conn, 401, %{error: "unauthorized"})
    end
  end

  get "/picker/:id" do
    cond do
      not authorized?(conn) ->
        json(conn, 401, %{error: "unauthorized"})

      get_req_header(conn, "origin") != [] ->
        json(conn, 403, %{error: "browser origins are not supported"})

      true ->
        case Jarvis2.MCP.Picker.fetch(id) do
          {:ok, request} ->
            conn |> put_resp_header("cache-control", "no-store") |> json(200, request)

          :error ->
            json(conn, 404, %{error: "request not found"})
        end
    end
  end

  post "/picker/:id" do
    cond do
      not authorized?(conn) ->
        json(conn, 401, %{error: "unauthorized"})

      get_req_header(conn, "origin") != [] ->
        json(conn, 403, %{error: "browser origins are not supported"})

      true ->
        case read_json(conn) do
          {:ok, body, conn} when is_map(body) ->
            case Jarvis2.MCP.Picker.answer(id, body) do
              :ok -> json(conn, 200, %{ok: true})
              :error -> json(conn, 400, %{error: "invalid or expired answer"})
            end

          {:ok, _, conn} ->
            json(conn, 400, %{error: "invalid answer"})

          {:error, status, conn} ->
            json(conn, status, %{error: "invalid or oversized JSON body"})
        end
    end
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

  defp read_json(conn) do
    case read_body(conn, length: @body_limit, read_length: @body_limit) do
      {:ok, body, conn} when byte_size(body) <= @body_limit ->
        case Jason.decode(body) do
          {:ok, value} -> {:ok, value, conn}
          {:error, _} -> {:error, 400, conn}
        end

      {:ok, _body, conn} ->
        {:error, 413, conn}

      {:more, _body, conn} ->
        {:error, 413, conn}

      {:error, _reason} ->
        {:error, 400, conn}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
