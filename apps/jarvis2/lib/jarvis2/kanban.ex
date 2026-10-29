defmodule Jarvis2.Kanban do
  @moduledoc "Cards and persistent interview rounds for the planning board."
  import Ecto.Query

  alias Jarvis2.{Journal, Repo, Runs}
  alias Jarvis2.Herdr.Mirror
  alias Jarvis2.Kanban.{Card, Feedback, Prompt, Round}
  alias Jarvis2.Runs.{Launcher, Run}

  def topic, do: "kanban"

  def list_cards do
    Card |> order_by(desc: :updated_at) |> Repo.all() |> Repo.preload([:run, :rounds, :feedback])
  end

  def get_card(id) do
    with {:ok, id} <- Ecto.UUID.cast(id), %Card{} = card <- Repo.get(Card, id) do
      Repo.preload(card, [:run, :rounds, :feedback], in_parallel: false)
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

  def ask_questions(run_id, questions) do
    cond do
      not Round.valid_questions?(questions) ->
        {:error, "Invalid questions or limits exceeded."}

      card = get_card_by_run(run_id) ->
        if Enum.any?(card.rounds, &(&1.status == :open)),
          do: {:error, "A round is already open."},
          else: ask(card, run_id, questions)

      true ->
        {:error, "Not a kanban run."}
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

    if byte_size(Prompt.answers(current)) > 6_000,
      do: Repo.rollback("Answers are too long to deliver; shorten them.")

    transition!(current.card_id, :awaiting_user, :agent)

    query =
      from r in Round,
        where: r.id == ^current.id and r.status == :open and r.updated_at == ^current.updated_at

    {count, _} = Repo.update_all(query, set: [status: :answered, updated_at: DateTime.utc_now()])
    if count != 1, do: Repo.rollback("The round changed; try again.")
    Repo.get!(Round, current.id)
  end

  def submit_plan(run_id, plan) do
    cond do
      not is_binary(plan) or byte_size(plan) > 20_000 or String.trim(plan) == "" ->
        {:error, "Invalid plan."}

      card = get_card_by_run(run_id) ->
        finish(card, run_id, plan)

      true ->
        {:error, "Not a kanban run."}
    end
  end

  defp finish(card, run_id, plan) do
    transaction(
      fn ->
        transition!(card.id, [:agent, :awaiting_user], :done, run_id: run_id, plan: plan)

        Repo.update_all(from(r in Round, where: r.card_id == ^card.id and r.status == :open),
          set: [status: :cancelled, updated_at: DateTime.utc_now()]
        )

        Repo.get!(Card, card.id)
      end,
      card.id,
      "kanban.plan"
    )
  end

  def move(%Card{column: :scratch} = card, to) when to in [:agent, "agent"] do
    with :ok <- availability(), do: start_or_resume(card, :scratch, nil)
  end

  def move(%Card{column: column} = card, to)
      when column in [:agent, :awaiting_user] and to in [:scratch, "scratch"] do
    transaction(
      fn ->
        transition!(card.id, [:agent, :awaiting_user], :scratch)
        current = get_card(card.id)

        stop_if_active!(current.run)

        Repo.update_all(from(r in Round, where: r.card_id == ^card.id and r.status == :open),
          set: [status: :cancelled, updated_at: DateTime.utc_now()]
        )

        Repo.get!(Card, card.id)
      end,
      card.id,
      "kanban.scratch"
    )
  end

  def move(%Card{}, _to), do: {:error, "That move is not allowed."}

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

  def reopen(%Card{column: :done} = card, text) when is_binary(text) do
    text = String.trim(text)
    changeset = Feedback.changeset(%Feedback{}, %{card_id: card.id, text: text})

    if changeset.valid? do
      with :ok <- availability(), do: start_or_resume(card, :done, text)
    else
      {:error, "Feedback is required and must be at most 1000 bytes."}
    end
  end

  def reopen(_, _), do: {:error, "That card cannot be reopened."}

  defp start_or_resume(card, from, feedback) do
    result =
      transaction(
        fn ->
          transition!(card.id, from, :agent)
          current = get_card(card.id)

          item =
            if feedback,
              do:
                Repo.insert!(Feedback.changeset(%Feedback{}, %{card_id: card.id, text: feedback})),
              else: nil

          prepare_agent!(current, item, feedback)
        end,
        card.id,
        "kanban.agent"
      )

    case result do
      {:ok, {:launch, run, item}} ->
        launch(run, item, card.id)
        {:ok, get_card(card.id)}

      {:ok, {:resume, _item}} ->
        schedule_delivery(card.id)
        {:ok, get_card(card.id)}

      error ->
        error
    end
  end

  defp prepare_agent!(%Card{run: %Run{} = run} = card, item, feedback) do
    if Run.active?(run), do: {:resume, item}, else: create_agent!(card, item, feedback)
  end

  defp prepare_agent!(card, item, feedback), do: create_agent!(card, item, feedback)

  defp create_agent!(card, item, feedback) do
    attrs = %{
      name: String.slice(card.title, 0, 64),
      cwd: card.cwd,
      task: Prompt.build(card, card.rounds, feedback)
    }

    case Runs.create_run(attrs) do
      {:ok, run} ->
        Repo.update_all(from(c in Card, where: c.id == ^card.id), set: [run_id: run.id])
        {:launch, run, item}

      {:error, _} ->
        Repo.rollback("Could not create the run; check its settings.")
    end
  end

  defp launch(run, item, card_id) do
    Task.Supervisor.start_child(Jarvis2.TaskSupervisor, fn ->
      Runs.launch(run, &record_launch_delivery(&1, item, card_id))
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
          %Round{} -> Prompt.answers(item)
          %Feedback{} -> Prompt.reopen(item.text)
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

  defp availability do
    view =
      try do
        Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))
      catch
        :exit, _ -> nil
      end

    Launcher.availability(view)
  end

  defp transition!(id, from, to, attrs \\ []) do
    now = DateTime.utc_now()
    query = from c in Card, where: c.id == ^id and c.column in ^List.wrap(from)
    query = if attrs[:run_id], do: where(query, [c], c.run_id == ^attrs[:run_id]), else: query
    changes = [column: to, updated_at: now] ++ Keyword.take(attrs, [:plan])
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
    Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, topic(), {:card, card})
  end
end
