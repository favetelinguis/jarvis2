defmodule Jarvis2.Settings do
  @moduledoc """
  User configuration, stored as a single row: which automations and agent actions are enabled and
  the defaults for new runs.

  `JARVIS2_SCENARIOS` can lock the set that may ever be enabled; the database can only narrow it.
  """
  alias Jarvis2.Repo
  alias Jarvis2.Settings.Setting

  @scenarios %{
    "attention" => "Notify when an agent is blocked or done",
    "agent_prompt" => "Send agent-to-agent prompts",
    "agent_spawn" => "Start sibling agents (MCP)",
    "run_command" => "Run shell commands in a new sibling pane (MCP)",
    "test_loop" => "Run mix test after an agent's turn and prompt it about failures",
    "sidebar_tokens" => "Show agent status in Herdr's sidebar",
    "pane_hygiene" => "Tidy sidebar tokens when panes change",
    "output_watcher" => "Notify when watched pane output matches",
    "custom_worker" => "Show Mix jobs as an agent in Herdr"
  }
  @atoms Map.new(Map.keys(@scenarios), &{&1, String.to_atom(&1)})

  def scenarios, do: Enum.sort(@scenarios)
  def known_scenarios, do: Map.keys(@scenarios)

  def get do
    Repo.get(Setting, 1) ||
      (Repo.insert!(%Setting{id: 1}, on_conflict: :nothing) && Repo.get!(Setting, 1))
  end

  def change(%Setting{} = setting \\ get(), attrs \\ %{}),
    do: Setting.changeset(setting, attrs, known_scenarios())

  def update(attrs) do
    with {:ok, setting} <- get() |> change(attrs) |> Repo.update() do
      apply_settings(setting)
      {:ok, setting}
    end
  end

  @doc "Scenarios that are enabled and permitted by the environment."
  def effective(%Setting{scenarios: enabled}) do
    allowed =
      Application.get_env(:jarvis2, :allowed_scenarios) ||
        Enum.map(known_scenarios(), &@atoms[&1])

    for name <- enabled, atom = @atoms[name], atom in allowed, do: atom
  end

  def allowed?(scenario),
    do: scenario in (Application.get_env(:jarvis2, :allowed_scenarios) || Map.values(@atoms))

  @doc "Publishes the effective scenarios where the guarded actions read them."
  def apply_settings(%Setting{} = setting \\ get()) do
    Application.put_env(:jarvis2, :live_scenarios, effective(setting))
    :ok
  end
end
