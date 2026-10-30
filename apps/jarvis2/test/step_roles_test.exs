defmodule Jarvis2.StepRolesTest do
  use Jarvis2.DataCase, async: false
  alias Jarvis2.{Journal, StepRoles}
  alias Jarvis2.Kanban.Kind

  test "defaults cover every step, assignments persist and reset" do
    for {kind, stage} <- StepRoles.steps() do
      assert StepRoles.role_name(kind, stage) == Kind.stage(kind, stage).role
      assert {:ok, _} = StepRoles.resolve(kind, stage)
    end

    assert {:ok, "researcher"} = StepRoles.assign(:plan, :planning, "researcher")
    assert StepRoles.role_name("plan", "planning") == "researcher"
    assert {:ok, %{name: "researcher"}} = StepRoles.resolve(:plan, :planning)
    assert [%{payload: %{"role" => "researcher"}}] = Journal.recent(type: "roles.assigned")
    assert {:ok, "planner"} = StepRoles.assign(:plan, :planning, nil)
    assert StepRoles.role_name(:plan, :planning) == "planner"
    assert {:error, _} = StepRoles.assign(:plan, :main, "planner")
    assert {:error, message} = StepRoles.assign(:plan, :planning, "missing")
    assert message =~ "missing"
  end

  test "resolve reports a removed role" do
    assert {:ok, _} = StepRoles.assign(:plan, :planning, "researcher")
    old = Application.fetch_env!(:jarvis2, :roles_dir)
    dir = Path.join(System.tmp_dir!(), "empty-roles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:jarvis2, :roles_dir, dir)

    on_exit(fn ->
      Application.put_env(:jarvis2, :roles_dir, old)
      File.rm_rf!(dir)
    end)

    assert {:error, message} = StepRoles.resolve(:plan, :planning)
    assert message =~ "researcher"
  end
end
