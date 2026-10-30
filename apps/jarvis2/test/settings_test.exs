defmodule Jarvis2.SettingsTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.{Runs, Settings}

  setup do
    for key <- [:live_scenarios, :allowed_scenarios] do
      old = Application.fetch_env(:jarvis2, key)

      on_exit(fn ->
        case old do
          {:ok, v} -> Application.put_env(:jarvis2, key, v)
          :error -> Application.delete_env(:jarvis2, key)
        end
      end)
    end

    Application.delete_env(:jarvis2, :allowed_scenarios)
    :ok
  end

  test "starts with the Pi, luna, low defaults and nothing enabled" do
    assert %{
             scenarios: [],
             default_kind: "pi",
             default_model: "openrouter/openai/gpt-6-luna",
             default_thinking: "low"
           } = Settings.get()

    assert Settings.get().id == 1
    assert Repo.aggregate(Jarvis2.Settings.Setting, :count) == 1
  end

  test "updating publishes the enabled scenarios to the guarded actions" do
    assert {:ok, _} =
             Settings.update(%{scenarios: ["agent_spawn", "attention", "attention", "subagents"]})

    assert Settings.get().scenarios == ["agent_spawn", "attention", "subagents"]

    assert Enum.sort(Application.get_env(:jarvis2, :live_scenarios)) == [
             :agent_spawn,
             :attention,
             :subagents
           ]

    assert {:ok, _} = Settings.update(%{scenarios: []})
    assert Application.get_env(:jarvis2, :live_scenarios) == []
  end

  test "the environment ceiling wins over what the database enables" do
    Application.put_env(:jarvis2, :allowed_scenarios, [:attention])
    assert {:ok, _} = Settings.update(%{scenarios: ["attention", "agent_spawn"]})

    assert Settings.get().scenarios == ["attention", "agent_spawn"]
    assert Application.get_env(:jarvis2, :live_scenarios) == [:attention]
    assert Settings.allowed?(:attention)
    refute Settings.allowed?(:agent_spawn)
  end

  test "subagents are accepted by the environment ceiling" do
    dir = Path.join(System.tmp_dir!(), "jarvis2-runtime-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    runtime = Path.expand("../../../config/runtime.exs", __DIR__)

    script =
      "config = Config.Reader.read!(#{inspect(runtime)}, env: :prod); IO.inspect(config[:jarvis2][:allowed_scenarios])"

    {output, 0} =
      System.cmd("elixir", ["-e", script],
        env: [
          {"JARVIS2_STATE_DIR", dir},
          {"JARVIS2_SCENARIOS", "subagents"},
          {"ERL_FLAGS", "+S 2"}
        ]
      )

    assert output =~ "[:subagents]"
  end

  test "rejects unknown scenarios and unsafe or unknown defaults" do
    for bad <- [
          %{scenarios: ["root_shell"]},
          %{default_model: "openrouter/x; rm -rf ~"},
          %{default_model: "nomodel"},
          %{default_thinking: "extreme"},
          %{default_kind: "nope"}
        ] do
      assert {:error, %Ecto.Changeset{valid?: false}} = Settings.update(bad)
    end

    assert Settings.get().scenarios == []
  end

  test "role overrides validate, remain independent, and follow changing fallbacks" do
    dir = Path.join(System.tmp_dir!(), "jarvis2-roles-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    old = Application.fetch_env!(:jarvis2, :roles_dir)
    Application.put_env(:jarvis2, :roles_dir, dir)

    on_exit(fn ->
      Application.put_env(:jarvis2, :roles_dir, old)
      File.rm_rf!(dir)
    end)

    file = Path.join(dir, "planner.md")
    File.write!(file, "---\nname: planner\nmodel: vendor/file\n---\nPlan")
    File.write!(Path.join(dir, "other.md"), "---\nname: other\n---\nOther")
    {:ok, planner} = Jarvis2.Roles.get("planner")
    {:ok, other} = Jarvis2.Roles.get("other")
    {:ok, _} = Settings.update(%{default_model: "vendor/default"})
    assert Settings.role_model(planner) == "vendor/file"
    assert Settings.role_model(other) == "vendor/default"
    assert {:ok, _} = Settings.save_role_model("planner", "vendor/local")
    assert {:ok, _} = Settings.save_role_model("other", "vendor/other")
    assert {:error, :invalid_model} = Settings.save_role_model("planner", "vendor/$(id)")
    assert {:error, :invalid_role} = Settings.save_role_model("missing", "vendor/local")
    assert Settings.role_model(planner) == "vendor/local"
    assert Settings.role_model(other) == "vendor/other"

    File.write!(file, "---\nname: planner\nmodel: vendor/new\n---\nPlan")
    {:ok, changed} = Jarvis2.Roles.get("planner")
    assert Settings.role_model(changed) == "vendor/local"
    assert {:ok, _} = Settings.save_role_model("planner", " ")
    assert Settings.role_model(changed) == "vendor/new"
    assert {:ok, _} = Settings.save_role_model("other", "")
    assert Settings.role_model(other) == "vendor/default"

    assert {:ok, _} = Settings.save_role_model("planner", "vendor/stale")
    File.rm!(file)
    assert {:error, :invalid_role} = Settings.save_role_model("planner", "")
    assert Settings.role_models()["planner"] == "vendor/stale"
    assert Settings.role_model(other) == "vendor/default"
  end

  test "role models remain local to each database and survive a repository restart" do
    dir = Path.join(System.tmp_dir!(), "jarvis2-installations-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    old = Application.fetch_env!(:jarvis2, :roles_dir)
    Application.put_env(:jarvis2, :roles_dir, dir)

    on_exit(fn ->
      Application.put_env(:jarvis2, :roles_dir, old)
      File.rm_rf!(dir)
    end)

    File.write!(Path.join(dir, "planner.md"), "---\nname: planner\nmodel: vendor/file\n---\nPlan")
    {:ok, role} = Jarvis2.Roles.get("planner")
    first = Path.join(dir, "first.db")
    second = Path.join(dir, "second.db")

    with_database(first, true, fn ->
      assert {:ok, _} = Settings.save_role_model("planner", "vendor/first")
    end)

    with_database(second, true, fn ->
      assert Settings.role_model(role) == "vendor/file"
      assert {:ok, _} = Settings.save_role_model("planner", "vendor/second")
      assert Settings.role_model(role) == "vendor/second"
    end)

    with_database(first, false, fn ->
      assert Settings.role_model(role) == "vendor/first"
    end)

    with_database(second, false, fn ->
      assert Settings.role_model(role) == "vendor/second"
    end)
  end

  defp with_database(path, migrate?, fun) do
    {:ok, pid} =
      Repo.start_link(name: nil, database: path, pool: DBConnection.ConnectionPool, pool_size: 1)

    previous = Repo.put_dynamic_repo(pid)

    try do
      if migrate? do
        migration = Jarvis2.Repo.Migrations.CreateRoleModels

        path =
          Path.expand("../priv/repo/migrations/20260101000021_create_role_models.exs", __DIR__)

        unless Code.ensure_loaded?(migration), do: Code.require_file(path)
        Ecto.Migrator.run(Repo, [{20_260_101_000_021, migration}], :up, all: true, log: false)
      end

      fun.()
    after
      Repo.put_dynamic_repo(previous)
      GenServer.stop(pid)
    end
  end

  test "new runs pick up the configured defaults" do
    {:ok, _} =
      Settings.update(%{
        default_model: "anthropic/claude-x",
        default_thinking: "high",
        default_kind: "claude"
      })

    assert %{model: "anthropic/claude-x", thinking: "high", kind: "claude"} = Runs.defaults()

    {:ok, run} = Runs.create_run(%{name: "n", task: "t", cwd: File.cwd!()})
    assert {run.model, run.thinking, run.kind} == {"anthropic/claude-x", "high", "claude"}
  end
end
