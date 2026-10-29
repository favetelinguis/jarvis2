defmodule Jarvis2Web.EventLiveTest do
  use Jarvis2Web.ConnCase, async: false

  alias Jarvis2.Journal

  setup %{conn: conn}, do: %{conn: sign_in(conn)}

  test "requires a session" do
    conn = Phoenix.ConnTest.build_conn() |> Map.put(:host, "127.0.0.1")
    assert redirected_to(get(conn, "/events")) == "/login"
  end

  test "lists recent events newest first and follows new ones", %{conn: conn} do
    {:ok, old} = Journal.record(%{source: :herdr, type: "pane.focused"})
    {:ok, view, _} = live(conn, "/events")
    assert has_element?(view, "#events-#{old.id}", "pane.focused")

    {:ok, fresh} = Journal.record(%{source: :mcp, type: "tool.whoami", payload: %{pane: "w1:p1"}})
    assert has_element?(view, "#events-#{fresh.id}", "tool.whoami")
    assert has_element?(view, "#events-#{fresh.id}", "w1:p1")
  end

  test "filters by source, type prefix and run, and keeps live updates consistent", %{conn: conn} do
    run_id = Ecto.UUID.generate()
    {:ok, a} = Journal.record(%{source: :mcp, type: "tool.whoami"})
    {:ok, b} = Journal.record(%{source: :ui, type: "run.created", run_id: run_id})
    {:ok, c} = Journal.record(%{source: :automation, type: "automation.attention"})

    {:ok, by_source, _} = live(conn, "/events?source=mcp")
    assert has_element?(by_source, "#events-#{a.id}")
    refute has_element?(by_source, "#events-#{b.id}")

    {:ok, by_type, _} = live(conn, "/events?type=automation.")
    assert has_element?(by_type, "#events-#{c.id}")
    refute has_element?(by_type, "#events-#{a.id}")

    {:ok, by_run, _} = live(conn, "/events?run=#{run_id}")
    assert has_element?(by_run, "#events-#{b.id}")
    refute has_element?(by_run, "#events-#{a.id}")

    {:ok, other} = Journal.record(%{source: :herdr, type: "pane.closed"})
    {:ok, match} = Journal.record(%{source: :mcp, type: "tool.log"})
    refute has_element?(by_source, "#events-#{other.id}")
    assert has_element?(by_source, "#events-#{match.id}")
  end

  test "changing a filter patches the URL", %{conn: conn} do
    {:ok, view, _} = live(conn, "/events")
    view |> form("#filter-form", filter: %{source: "ui", type: "run."}) |> render_change()
    assert_patch(view, "/events?source=ui&type=run.")
  end

  test "ignores a malformed run id and unknown sources", %{conn: conn} do
    {:ok, _} = Journal.record(%{source: :mcp, type: "tool.whoami"})
    {:ok, view, _} = live(conn, "/events?run=not-a-uuid&source=bogus")
    assert has_element?(view, "td", "tool.whoami")
  end
end
