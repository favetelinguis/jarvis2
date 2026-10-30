defmodule Jarvis2.Kanban do
  @moduledoc "Cards and persistent question rounds for the deliverables board."
  import Ecto.Query

  alias Jarvis2.{Journal, Repo, Runs, StepRoles}
  alias Jarvis2.Herdr.Actions
  alias Jarvis2.Herdr.Mirror
  alias Jarvis2.Kanban.{Card, Feedback, Kind, Prompt, Round, SkillUse, Slides}
  alias Jarvis2.Runs.{Launcher, Run}

  def topic, do: "kanban"

  def list_cards do
    Card |> order_by(desc: :updated_at) |> Repo.all() |> Repo.preload([:run, :rounds, :feedback])
  end

  def get_card(id) do
    with {:ok, id} <- Ecto.UUID.cast(id), %Card{} = card <- Repo.get(Card, id) do
      Repo.preload(card, [:run, :rounds, :feedback, :skill_uses], in_parallel: false)
    else
      _ -> nil
    end
  end

  def get_card_by_run(run_id) do
    with {:ok, id} <- Ecto.UUID.cast(run_id), %Card{} = card <- Repo.get_by(Card, run_id: id) do
      get_card(card.id)
    else
      _ -> nil
    end
  end

  def get_round(id) do
    with {:ok, id} <- Ecto.UUID.cast(id), do: Repo.get(Round, id)
  end

  def change_card(card \\ %Card{}, attrs \\ %{}), do: Card.changeset(card, attrs)

  def create_card(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    attrs =
      Map.put_new(attrs, "cwd", Application.get_env(:jarvis2, :mix_project_dir, File.cwd!()))

    with {:ok, card} <- %Card{} |> Card.changeset(attrs) |> Repo.insert() do
      changed(card, "kanban.created")
      {:ok, card}
    end
  end

  def report_skill(run_id, name, reason) do
    with %Card{} = card <- get_card_by_run(run_id),
         true <- valid_skill_text?(name, 100) and valid_skill_text?(reason, 500) do
      insert_skill(card.id, run_id, name, reason)
    else
      nil -> {:error, "Not a kanban run."}
      false -> {:error, "Invalid skill name or reason."}
    end
  end

  defp insert_skill(card_id, run_id, name, reason) do
    :global.trans({{__MODULE__, :report_skill, card_id}, self()}, fn ->
      transaction(
        fn -> record_skill!(card_id, run_id, name, reason) end,
        card_id,
        "kanban.skill"
      )
    end)
  end

  defp valid_skill_text?(text, max) when is_binary(text),
    do: byte_size(text) <= max and String.valid?(text) and String.trim(text) != ""

  defp valid_skill_text?(_, _), do: false

  defp record_skill!(card_id, run_id, name, reason) do
    card = Repo.get_by(Card, id: card_id, run_id: run_id)
    if is_nil(card), do: Repo.rollback("Not a kanban run.")

    count =
      Repo.aggregate(
        from(s in SkillUse, where: s.card_id == ^card_id and s.stage == ^card.stage),
        :count
      )

    if count >= 50, do: Repo.rollback("Skill report limit reached for this stage.")

    Repo.insert!(%SkillUse{
      card_id: card_id,
      run_id: run_id,
      stage: card.stage,
      name: name,
      reason: reason
    })
  end

  def ask_questions(run_id, questions) do
    case get_card_by_run(run_id) do
      nil ->
        {:error, "Not a kanban run."}

      card ->
        cond do
          not Round.valid_questions?(questions, Kind.get(card.kind).max_questions) ->
            {:error,
             "Invalid questions or limits exceeded (maximum #{Kind.get(card.kind).max_questions})."}

          Enum.any?(card.rounds, &(&1.status == :open)) ->
            {:error, "A round is already open."}

          true ->
            ask(card, run_id, questions)
        end
    end
  end

  defp ask(card, run_id, questions) do
    transaction(
      fn ->
        transition!(card.id, :agent, :awaiting_user, run_id: run_id)
        rounds = Repo.all(from r in Round, where: r.card_id == ^card.id)
        number = Enum.reduce(rounds, 0, &max(&1.number, &2)) + 1
        first = Enum.reduce(rounds, 1, &(length(&1.questions) + &2))

        round = %Round{
          card_id: card.id,
          number: number,
          questions: Round.normalize_questions(questions, first)
        }

        Repo.insert!(round)
      end,
      card.id,
      "kanban.questions"
    )
  end

  def save_draft(%Round{} = round, answers) do
    if Round.valid_answers?(round, answers) do
      now = DateTime.utc_now()

      {count, _} =
        Repo.update_all(from(r in Round, where: r.id == ^round.id and r.status == :open),
          set: [answers: answers, updated_at: now]
        )

      if count == 1 do
        saved = get_round(round.id)
        changed(get_card(round.card_id), "kanban.draft")
        {:ok, saved}
      else
        {:error, "The round is no longer open."}
      end
    else
      {:error, "Invalid answers."}
    end
  end

  def submit_answers(%Round{} = round) do
    transaction(fn -> answer_round!(round.id) end, round.card_id, "kanban.answered")
    |> case do
      {:ok, answered} = result ->
        schedule_delivery(answered.card_id)
        result

      error ->
        error
    end
  end

  defp answer_round!(id) do
    current = Repo.get(Round, id)

    if is_nil(current) or current.status != :open,
      do: Repo.rollback("The round is no longer open.")

    unless Round.valid_answers?(current, current.answers) and Round.complete?(current),
      do: Repo.rollback("Answer every question first.")

    card = Repo.get!(Card, current.card_id)

    unless Actions.valid_prompt_text?(Prompt.answers(current, card.stage)),
      do:
        Repo.rollback(
          "Answers are invalid or too long to deliver; remove control characters or shorten them."
        )

    transition!(current.card_id, :awaiting_user, :agent)

    query =
      from r in Round,
        where: r.id == ^current.id and r.status == :open and r.updated_at == ^current.updated_at

    {count, _} = Repo.update_all(query, set: [status: :answered, updated_at: DateTime.utc_now()])
    if count != 1, do: Repo.rollback("The round changed; try again.")
    Repo.get!(Round, current.id)
  end

  def submit_deliverable(run_id, content) do
    case get_card_by_run(run_id) do
      nil ->
        {:error, "Not a kanban run."}

      card ->
        with :ok <- validate_deliverable(card, content), do: finish(card, run_id, content)
    end
  end

  defp validate_deliverable(card, content) do
    max = Kind.stage(card.kind, card.stage).max_deliverable

    cond do
      not is_binary(content) or String.trim(content) == "" -> {:error, "Invalid deliverable."}
      byte_size(content) > max -> {:error, "Deliverable exceeds #{max} bytes; shorten it."}
      Kind.deliverable_type(card.kind) == :html -> Slides.validate(content)
      true -> :ok
    end
  end

  defp finish(card, run_id, content) do
    transaction(
      fn ->
        transition!(card.id, [:agent, :awaiting_user], :done,
          run_id: run_id,
          deliverable: content
        )

        Repo.update_all(from(r in Round, where: r.card_id == ^card.id and r.status == :open),
          set: [status: :cancelled, updated_at: DateTime.utc_now()]
        )

        Repo.get!(Card, card.id)
      end,
      card.id,
      "kanban.deliverable"
    )
  end

  def advance(%Card{id: id} = card) do
    :global.trans({{__MODULE__, :advance, id}, self()}, fn -> advance_current(card) end)
  end

  defp advance_current(card) do
    current = get_card(card.id)

    with {:ok, next_stage} <- advanceable(current, card),
         :ok <- availability(),
         started_at = DateTime.utc_now(),
         next_card = %{
           current
           | stage: next_stage,
             stage_started_at: started_at,
             deliverable: nil
         },
         {:ok, prepared} <- prepare_run(next_card, nil, false),
         :ok <- write_plan(current.run.cwd, current.deliverable) do
      advance_transaction(current, next_stage, started_at, {:ok, prepared})
    end
  end

  defp advanceable(nil, _card), do: {:error, "The card changed; reload it and try again."}

  defp advanceable(current, card) do
    stage = Kind.stage(current.kind, current.stage)

    cond do
      current.updated_at != card.updated_at ->
        {:error, "The card changed; reload it and try again."}

      current.column != :done or is_nil(stage) or is_nil(stage.advance) ->
        {:error, "This card cannot be advanced."}

      not is_binary(current.deliverable) or String.trim(current.deliverable) == "" ->
        {:error, "A deliverable is required before advancing."}

      is_nil(current.run_id) ->
        {:error, "The card has no planner run."}

      true ->
        {:ok, stage.advance.to}
    end
  end

  defp advance_transaction(card, next_stage, started_at, prepared) do
    result =
      Repo.transaction(fn ->
        transition!(card.id, :done, :agent,
          run_id: card.run_id,
          expected_updated_at: card.updated_at,
          stage: next_stage,
          stage_started_at: started_at,
          accepted_plan: card.deliverable,
          deliverable: nil
        )

        mark_stale_delivered(card.id)
        current = get_card(card.id)

        {:launch, run, _} =
          created = create_agent!(current, nil, nil, :advance, card.run_id, prepared)

        Journal.record(%{
          source: :ui,
          type: "kanban.advanced",
          run_id: run.id,
          payload: %{card_id: card.id, plan_bytes: byte_size(card.deliverable)}
        })

        created
      end)

    case result do
      {:ok, {:launch, run, _}} ->
        broadcast_card(get_card(card.id))
        launch(run, nil, card.id, card.title, placement(card.run))
        {:ok, get_card(card.id)}

      error ->
        error
    end
  end

  defp write_plan(cwd, content) do
    target = Path.join(cwd, "PLAN.md")
    temp = Path.join(cwd, ".PLAN.md-" <> Ecto.UUID.generate())

    result =
      with {:ok, file} <- File.open(temp, [:write, :exclusive, :binary]),
           result <- IO.binwrite(file, content),
           close <- File.close(file),
           :ok <- result,
           :ok <- close do
        File.rename(temp, target)
      end

    if result != :ok, do: File.rm(temp)
    if result == :ok, do: :ok, else: {:error, "Could not write PLAN.md in the working directory."}
  end

  defp placement(%Run{tab_id: tab_id} = run) when is_binary(tab_id) and tab_id != "" do
    view = current_view()

    case Launcher.find(run, view) do
      {%{"tab_id" => ^tab_id}, _} -> {:split, run.pane_id, tab_id}
      _ -> :tab
    end
  end

  defp placement(_), do: :tab

  def move(%Card{column: :scratch} = card, to) when to in [:agent, "agent"] do
    with :ok <- availability(), do: start_or_resume(card, :scratch, nil)
  end

  def move(%Card{column: :archive}, _to),
    do: {:error, "Restore an archived card with a reason."}

  def move(%Card{column: column} = card, to)
      when column in [:agent, :awaiting_user] and to in [:scratch, "scratch"] do
    stop_and_move(card, :scratch, [:agent, :awaiting_user])
  end

  def move(%Card{column: column} = card, to)
      when column != :archive and to in [:archive, "archive"] do
    stop_and_move(card, :archive, column)
  end

  def move(%Card{}, _to), do: {:error, "That move is not allowed."}

  defp stop_and_move(card, target, from) do
    transaction(
      fn ->
        transition!(card.id, from, target)
        current = get_card(card.id)
        stop_if_active!(current.run)

        Repo.update_all(from(r in Round, where: r.card_id == ^card.id and r.status == :open),
          set: [status: :cancelled, updated_at: DateTime.utc_now()]
        )

        Repo.get!(Card, card.id)
      end,
      card.id,
      "kanban.#{target}"
    )
  end

  defp stop_if_active!(%Run{status: :starting}),
    do: Repo.rollback("Wait for the agent to finish starting.")

  defp stop_if_active!(%Run{} = run) do
    if Run.active?(run) do
      case Runs.stop_run(run) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp stop_if_active!(_), do: :ok

  def reopen(%Card{column: column} = card, text)
      when column in [:done, :archive] and is_binary(text) do
    if Actions.valid_prompt_characters?(text),
      do: reopen_valid(card, String.trim(text)),
      else: {:error, "Feedback produces an invalid or oversized prompt."}
  end

  def reopen(_, _), do: {:error, "That card cannot be reopened."}

  defp reopen_valid(card, text) do
    changeset = Feedback.changeset(%Feedback{}, %{card_id: card.id, text: text})

    cond do
      not changeset.valid? ->
        {:error, "Feedback is required and must be at most 1000 bytes."}

      not Actions.valid_prompt_text?(Prompt.reopen(text, card.kind, card.stage, card.id)) ->
        {:error, "Feedback produces an invalid or oversized prompt."}

      true ->
        with :ok <- availability(), do: start_or_resume(card, card.column, text)
    end
  end

  defp start_or_resume(card, from, feedback) do
    result =
      transaction(
        fn ->
          transition!(card.id, from, :agent)
          current = get_card(card.id)
          if from == :archive, do: mark_stale_delivered(card.id)

          store_deck!(current)

          item =
            if feedback,
              do:
                Repo.insert!(Feedback.changeset(%Feedback{}, %{card_id: card.id, text: feedback})),
              else: nil

          prepare_agent!(current, item, feedback, from)
        end,
        card.id,
        "kanban.agent"
      )

    case result do
      {:ok, {:launch, run, item}} ->
        launch(run, item, card.id, card.title)
        {:ok, get_card(card.id)}

      {:ok, {:resume, _item}} ->
        schedule_delivery(card.id)
        {:ok, get_card(card.id)}

      error ->
        error
    end
  end

  defp store_deck!(card) do
    if card.deliverable && Kind.deliverable_type(card.kind) == :html do
      case Slides.store(card) do
        :ok -> :ok
        {:error, message} -> Repo.rollback(message)
      end
    end
  end

  defp mark_stale_delivered(card_id) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(r in Round,
        where: r.card_id == ^card_id and r.status == :answered and is_nil(r.delivered_at)
      ),
      set: [delivered_at: now]
    )

    Repo.update_all(from(f in Feedback, where: f.card_id == ^card_id and is_nil(f.delivered_at)),
      set: [delivered_at: now]
    )
  end

  defp prepare_agent!(%Card{run: %Run{} = run} = card, item, feedback, from)
       when from != :archive do
    if Run.active?(run), do: {:resume, item}, else: create_agent!(card, item, feedback, from)
  end

  defp prepare_agent!(card, item, feedback, from), do: create_agent!(card, item, feedback, from)

  defp create_agent!(card, item, feedback, from, parent_run_id \\ nil, prepared \\ nil) do
    restored = from == :archive

    {role, task} =
      case prepared || prepare_run(card, feedback, restored) do
        {:ok, result} -> result
        {:error, message} -> Repo.rollback(message)
      end

    attrs = %{
      name: String.slice(card.title, 0, 64),
      cwd: card.cwd,
      worktree: card.worktree,
      task: task,
      role: role.name,
      model: role.model,
      thinking: role.effort,
      session_id: session_id(card, restored),
      parent_run_id: parent_run_id
    }

    case Runs.create_run(attrs) do
      {:ok, run} ->
        Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [run_id: run.id])
        {:launch, run, item}

      {:error, _} ->
        Repo.rollback("Could not create the run; check its settings.")
    end
  end

  defp session_id(%Card{run: %Run{kind: "pi", session_id: id}}, true) when is_binary(id),
    do: id

  defp session_id(_card, _restored), do: Ecto.UUID.generate()

  defp prepare_run(card, feedback, restored) do
    with {:ok, role} <- StepRoles.resolve(card.kind, card.stage) do
      task = Prompt.build(card, card.rounds, feedback, role: role, restored: restored)
      name = String.slice(card.title, 0, 64)
      text = Jarvis2.Runs.Prompt.build(%{name: name, task: task})

      if Actions.valid_prompt_characters?(task) and Actions.valid_prompt_text?(text),
        do: {:ok, {role, task}},
        else:
          {:error,
           "Role #{inspect(role.name)} and required card content produce an invalid prompt or exceed 65536 bytes; shorten the role or card content."}
    end
  end

  defp launch(run, item, card_id, title, placement \\ :tab) do
    Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn ->
      Runs.launch(run, &record_launch_delivery(&1, item, card_id), title, placement)
    end)
  end

  defp record_launch_delivery("submitted", %Feedback{} = item, card_id) do
    mark_delivered(item)
    changed(get_card(card_id), "kanban.delivery")
  end

  defp record_launch_delivery(_, _, _), do: :ok

  def retry_delivery(%Card{id: id}) do
    case pending(id) do
      nil ->
        {:error, "No delivery is pending."}

      _ ->
        schedule_delivery(id)
        {:ok, get_card(id)}
    end
  end

  def pending(card_id) do
    rounds =
      Repo.all(
        from r in Round,
          where: r.card_id == ^card_id and r.status == :answered and is_nil(r.delivered_at)
      )

    feedback =
      Repo.all(from f in Feedback, where: f.card_id == ^card_id and is_nil(f.delivered_at))

    Enum.min_by(rounds ++ feedback, & &1.inserted_at, DateTime, fn -> nil end)
  end

  defp schedule_delivery(card_id) do
    Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn ->
      :global.trans({{__MODULE__, card_id}, self()}, fn -> deliver(card_id) end)
    end)
  end

  defp deliver(card_id), do: deliver_item(get_card(card_id), pending(card_id))

  defp deliver_item(%Card{column: :agent, run: %Run{} = run} = card, item)
       when not is_nil(item) do
    if Run.active?(run) do
      text =
        case item do
          %Round{} -> Prompt.answers(item, card.stage)
          %Feedback{} -> Prompt.reopen(item.text, card.kind, card.stage, card.id)
        end

      valid = fn -> delivery_valid?(card.id, run.id, item) end
      wait = Application.get_env(:jarvis2, :kanban_delivery_wait_ms, 120_000)

      delivered? =
        case Runs.prompt_run(run, text, wait_ms: wait, valid: valid) do
          {:ok, _} -> match?({:ok, _}, mark_delivered(item))
          {:error, _} -> false
        end

      next? = delivered? && not is_nil(pending(card.id))
      changed(get_card(card.id), "kanban.delivery")
      if next?, do: deliver(card.id)
    end
  end

  defp deliver_item(_, _), do: :ok

  defp delivery_valid?(card_id, run_id, item) do
    case get_card(card_id) do
      %Card{column: :agent, run_id: ^run_id} -> pending_item?(item)
      _ -> false
    end
  end

  defp pending_item?(%Round{id: id}),
    do: match?(%Round{status: :answered, delivered_at: nil}, Repo.get(Round, id))

  defp pending_item?(%Feedback{id: id}),
    do: match?(%Feedback{delivered_at: nil}, Repo.get(Feedback, id))

  defp mark_delivered(item) do
    item |> Ecto.Changeset.change(delivered_at: DateTime.utc_now()) |> Repo.update()
  end

  defp availability, do: Launcher.availability(current_view())

  defp current_view do
    Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))
  catch
    :exit, _ -> nil
  end

  defp transition!(id, from, to, attrs \\ []) do
    now = DateTime.utc_now()
    query = from c in Card, where: c.id == ^id and c.column in ^List.wrap(from)
    query = if attrs[:run_id], do: where(query, [c], c.run_id == ^attrs[:run_id]), else: query

    query =
      if attrs[:expected_updated_at],
        do: where(query, [c], c.updated_at == ^attrs[:expected_updated_at]),
        else: query

    changes =
      [column: to, updated_at: now] ++
        Keyword.take(attrs, [:deliverable, :stage, :stage_started_at, :accepted_plan])

    {count, _} = Repo.update_all(query, set: changes)
    if count != 1, do: Repo.rollback("The card changed or that move is not allowed.")
  end

  defp transaction(fun, card_id, event) do
    case Repo.transaction(fun) do
      {:ok, result} ->
        changed(get_card(card_id), event)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp changed(nil, _event), do: :ok

  defp changed(card, event) do
    Journal.record(%{source: :ui, type: event, run_id: card.run_id, payload: %{card_id: card.id}})
    broadcast_card(card)
  end

  defp broadcast_card(card),
    do: Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, topic(), {:card, card})
end
