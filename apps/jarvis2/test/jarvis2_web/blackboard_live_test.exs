defmodule Jarvis2Web.BlackboardLiveTest do
  use Jarvis2Web.ConnCase, async: false

  alias Jarvis2.{Blackboard, Runs}

  setup %{conn: conn}, do: %{conn: sign_in(conn)}

  test "requires a session" do
    conn = Phoenix.ConnTest.build_conn() |> Map.put(:host, "127.0.0.1")
    assert redirected_to(get(conn, "/blackboard")) == "/login"
  end

  test "shows an empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/blackboard")
    assert html =~ "The blackboard is empty."
  end

  test "adds, edits and deletes entries as JSON", %{conn: conn} do
    {:ok, view, _} = live(conn, "/blackboard")

    view |> form("#entry-form", entry: %{key: "plan", value: ~s({"step": 1})}) |> render_submit()
    assert Blackboard.get("plan") == {:ok, %{"step" => 1}}
    assert render(view) =~ "Saved plan."
    assert has_element?(view, "code", "plan")

    view |> element("button", "Edit") |> render_click()
    assert render(view) =~ "&quot;step&quot;: 1"

    view |> form("#entry-form", entry: %{key: "plan", value: "[1, 2]"}) |> render_submit()
    assert Blackboard.get("plan") == {:ok, [1, 2]}

    view |> element("button", "Delete") |> render_click()
    assert Blackboard.get("plan") == :error
    assert render(view) =~ "The blackboard is empty."
  end

  test "rejects values that are not JSON, invalid keys and a full board", %{conn: conn} do
    {:ok, view, _} = live(conn, "/blackboard")

    view |> form("#entry-form", entry: %{key: "k", value: "not json"}) |> render_submit()
    assert render(view) =~ "must be valid JSON"

    view |> form("#entry-form", entry: %{key: "  ", value: "1"}) |> render_submit()
    assert render(view) =~ "Invalid key"
    assert Blackboard.list() == %{}

    for n <- 1..256, do: :ok = Blackboard.put("k#{n}", n)
    view |> form("#entry-form", entry: %{key: "extra", value: "1"}) |> render_submit()
    assert render(view) =~ "The blackboard is full"
  end

  test "follows writes made by agents, with the run that wrote them", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{name: "writer", task: "t", cwd: File.cwd!()})
    {:ok, view, _} = live(conn, "/blackboard")

    :ok = Blackboard.put("note", "hello", run.id)
    assert has_element?(view, "code", "note")
    assert has_element?(view, "span", "writer")
    refute has_element?(view, "a", "writer")
  end

  test "values are escaped", %{conn: conn} do
    :ok = Blackboard.put("xss", "<script>alert(1)</script>")
    {:ok, _view, html} = live(conn, "/blackboard")
    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
  end
end
