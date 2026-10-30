defmodule Jarvis2.Settings do
  @moduledoc """
  User configuration: enabled automations and agent actions, defaults for new runs,
  and local model overrides for roles.

  `JARVIS2_SCENARIOS` can lock the set that may ever be enabled; the database can only narrow it.
  """
  import Ecto.Query, only: [from: 2]

  alias Jarvis2.{Repo, Roles}
  alias Jarvis2.Runs.Run
  alias Jarvis2.Settings.{RoleModel, Setting}

  @scenarios %{
    "attention" => "Notify when an agent is blocked or done",
    "agent_prompt" => "Send agent-to-agent prompts",
    "agent_spawn" => "Start sibling agents (MCP)",
    "subagents" => "Let runs start subagents (MCP)",
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

  @doc "All saved role model overrides, including those for roles no longer present."
  def role_models do
    Map.new(Repo.all(RoleModel), &{&1.role, &1.model})
  end

  @doc "The model used for a new run of this role."
  def role_model(%Roles.Role{} = role) do
    override = Repo.get(RoleModel, role.name)
    if override, do: override.model, else: role.model || get().default_model
  end

  def effective_role_model(%Roles.Role{} = role, %Setting{} = setting, overrides) do
    overrides[role.name] || role.model || setting.default_model
  end

  @doc "Save or clear the model override for a currently valid role."
  def save_role_model(name, model) do
    case Roles.get(name) do
      {:ok, _role} -> persist_role_model(name, model)
      {:error, _} -> {:error, :invalid_role}
    end
  end

  defp persist_role_model(name, model) do
    cond do
      is_binary(model) and String.valid?(model) and String.trim(model) == "" ->
        Repo.delete_all(from(r in RoleModel, where: r.role == ^name))
        {:ok, :cleared}

      Run.valid_model?(model) ->
        Repo.insert(%RoleModel{role: name, model: model},
          on_conflict: {:replace, [:model]},
          conflict_target: :role
        )

      true ->
        {:error, :invalid_model}
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
