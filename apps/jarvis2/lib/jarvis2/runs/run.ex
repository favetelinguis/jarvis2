defmodule Jarvis2.Runs.Run do
  @moduledoc "One agent job started from the UI or by another agent."
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:starting, :working, :blocked, :done, :finished, :failed, :lost, :stopped]
  @active [:starting, :working, :blocked, :done]
  @thinking ~w(off minimal low medium high xhigh max)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "runs" do
    field(:name, :string)
    field(:kind, :string, default: "pi")
    field(:role, :string)
    field(:model, :string)
    field(:thinking, :string)
    field(:cwd, :string)
    field(:worktree, :string, default: "main")
    field(:workspace_id, :string)
    field(:task, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :starting)
    field(:session_id, :string)
    field(:tab_id, :string)
    field(:pane_id, :string)
    field(:terminal_id, :string)
    field(:agent_name, :string)
    field(:parent_run_id, :binary_id)
    field(:spawned_by_run_id, :binary_id)
    field(:result, :map)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def thinking_levels, do: @thinking

  @doc "Statuses in which the run may still own a pane."
  def active?(%__MODULE__{status: status}), do: status in @active

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :name,
      :role,
      :kind,
      :model,
      :thinking,
      :cwd,
      :worktree,
      :task,
      :parent_run_id,
      :spawned_by_run_id,
      :session_id
    ])
    |> validate_required([:name, :kind, :model, :thinking, :cwd, :worktree, :task])
    |> validate_change(:worktree, fn :worktree, value ->
      if Jarvis2.Herdr.Workspaces.valid_worktree?(value), do: [], else: [worktree: "is invalid"]
    end)
    |> validate_length(:name, max: 64)
    |> validate_prompt()
    |> validate_inclusion(:kind, Jarvis2.Herdr.Actions.agent_kinds())
    |> validate_inclusion(:thinking, @thinking)
    |> validate_format(:session_id, ~r/\A[A-Za-z0-9]([A-Za-z0-9._-]{0,62}[A-Za-z0-9])?\z/)
    |> validate_model_field(:model)
    |> validate_cwd()
  end

  defp validate_prompt(changeset) do
    name = get_field(changeset, :name)
    task = get_field(changeset, :task)

    valid = fn text -> Jarvis2.Herdr.Actions.valid_prompt_characters?(text) end

    if is_binary(name) and is_binary(task) and
         not (valid.(name) and valid.(task) and
                Jarvis2.Herdr.Actions.valid_prompt_text?(
                  Jarvis2.Runs.Prompt.build(%{name: name, task: task})
                )) do
      add_error(changeset, :task, "complete prompt is invalid or exceeds 65536 bytes")
    else
      changeset
    end
  end

  @doc "A Mix job: no agent, model or thinking level; the task is the allow-listed Mix task."
  def mix_changeset(run, attrs) do
    run
    |> cast(attrs, [:task, :cwd, :parent_run_id])
    |> put_change(:name, "mix " <> to_string(attrs[:task]))
    |> put_change(:kind, "mix")
    |> put_change(:model, "n/a")
    |> put_change(:thinking, "off")
    |> put_change(:status, :working)
    |> put_change(:started_at, DateTime.utc_now())
    |> validate_required([:task, :cwd])
    |> validate_inclusion(:task, Jarvis2.MCP.MixRunner.tasks())
  end

  @doc "Records where the run's agent lives or how it ended."
  def progress_changeset(run, attrs) do
    cast(run, attrs, [
      :status,
      :cwd,
      :workspace_id,
      :tab_id,
      :pane_id,
      :terminal_id,
      :agent_name,
      :result,
      :started_at,
      :finished_at
    ])
  end

  def valid_model?(model) when is_binary(model),
    do:
      byte_size(model) <= 128 and
        Regex.match?(~r{\A[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._:/-]*\z}, model)

  def valid_model?(_), do: false

  # The model becomes agent arguments typed into a shell, so only plain identifier characters pass.
  @doc false
  def validate_model_field(changeset, field) do
    validate_change(changeset, field, fn ^field, model ->
      if valid_model?(model),
        do: [],
        else: [{field, "must look like provider/model"}]
    end)
  end

  @doc false
  def validate_cwd(changeset) do
    validate_change(changeset, :cwd, fn :cwd, cwd ->
      cond do
        Path.type(cwd) != :absolute -> [cwd: "must be an absolute path"]
        not File.dir?(cwd) -> [cwd: "is not a directory"]
        true -> []
      end
    end)
  end
end
