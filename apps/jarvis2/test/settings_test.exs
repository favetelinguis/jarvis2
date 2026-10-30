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
