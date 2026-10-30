defmodule Jarvis2Web.RolesLiveTest do
  use Jarvis2Web.ConnCase, async: false
  alias Jarvis2.StepRoles

  setup %{conn: conn}, do: %{conn: sign_in(conn)}

  test "requires authentication" do
    conn = Phoenix.ConnTest.build_conn() |> Map.put(:host, "127.0.0.1")
    assert redirected_to(get(conn, "/roles")) == "/login"
  end

  test "lists roles and steps and persists assignments", %{conn: conn} do
    {:ok, view, html} = live(conn, "/roles")
    assert html =~ "planner"
    assert html =~ "implementation"
    assert html =~ "(default)"
    view |> form("#role-plan-planning", %{role: "researcher"}) |> render_change()
    assert StepRoles.role_name(:plan, :planning) == "researcher"
    assert render(view) =~ "Role assignment saved."

    assert render_hook(view, "assign", %{
             "kind" => "plan",
             "stage" => "planning",
             "role" => "unknown"
           }) =~ "unknown"

    assert StepRoles.role_name(:plan, :planning) == "researcher"
  end

  test "shows invalid role files and warns on missing mappings", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "roles-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "planner.md"), "---\nname: wrong\n---\nbody")
    old = Application.fetch_env!(:jarvis2, :roles_dir)
    Application.put_env(:jarvis2, :roles_dir, dir)

    on_exit(fn ->
      Application.put_env(:jarvis2, :roles_dir, old)
      File.rm_rf!(dir)
    end)

    {:ok, view, html} = live(conn, "/roles")
    assert html =~ "name must match file stem"
    assert html =~ "missing or invalid"
    File.write!(Path.join(dir, "planner.md"), "---\nname: planner\n---\nbody")
    assert render_click(view, "reload") =~ "planner"
    refute has_element?(view, "#role-plan-planning option[value=planner]", "missing or invalid")
  end
end
