defmodule Jarvis2.Runs.Run do
  @moduledoc "One agent job started from the UI or by another agent."
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:starting, :dry_run, :working, :blocked, :done, :failed, :lost, :stopped]
  @active [:starting, :working, :blocked, :done]
  @thinking ~w(off minimal low medium high xhigh max)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "runs" do
    field(:name, :string)
    field(:kind, :string, default: "pi")
    field(:model, :string)
    field(:thinking, :string)
    field(:cwd, :string)
    field(:task, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :starting)
    field(:pane_id, :string)
    field(:terminal_id, :string)
    field(:agent_name, :string)
    field(:parent_run_id, :binary_id)
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
    |> cast(attrs, [:name, :kind, :model, :thinking, :cwd, :task, :parent_run_id])
    |> validate_required([:name, :kind, :model, :thinking, :cwd, :task])
    |> validate_length(:name, max: 64)
    |> validate_length(:task, max: 6_000, count: :bytes)
    |> validate_inclusion(:kind, Jarvis2.Herdr.Actions.agent_kinds())
    |> validate_inclusion(:thinking, @thinking)
    |> validate_model_field(:model)
    |> validate_cwd()
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
      :pane_id,
      :terminal_id,
      :agent_name,
      :result,
      :started_at,
      :finished_at
    ])
  end

  # The model becomes agent arguments typed into a shell, so only plain identifier characters pass.
  @doc false
  def validate_model_field(changeset, field) do
    validate_change(changeset, field, fn ^field, model ->
      if Regex.match?(~r{\A[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._:/-]*\z}, model) and
           byte_size(model) <= 128,
         do: [],
         else: [{field, "must look like provider/model"}]
    end)
  end

  defp validate_cwd(changeset) do
    validate_change(changeset, :cwd, fn :cwd, cwd ->
      cond do
        Path.type(cwd) != :absolute -> [cwd: "must be an absolute path"]
        not File.dir?(cwd) -> [cwd: "is not a directory"]
        true -> []
      end
    end)
  end
end
