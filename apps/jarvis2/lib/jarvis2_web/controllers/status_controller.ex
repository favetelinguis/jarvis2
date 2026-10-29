defmodule Jarvis2Web.StatusController do
  use Jarvis2Web, :controller

  alias Jarvis2.Herdr.Mirror

  def healthz(conn, _params), do: json(conn, %{status: "ok"})

  def status(conn, _params) do
    view = Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))
    calls = Jarvis2.Journal.count(source: :mcp)

    summary =
      case view do
        %{stale: false, snapshot: %{"agents" => agents}} ->
          blocked = Enum.count(agents, &(&1["agent_status"] == "blocked"))
          "◆ #{length(agents)} agents · #{blocked} blocked · #{calls} mcp calls\n"

        _ ->
          "◆ offline · #{calls} mcp calls\n"
      end

    text(conn, summary)
  end
end
