defmodule Jarvis2.Questions do
  @moduledoc """
  Questions and approvals that a run's agent puts to the human. The agent gets a ticket (the
  question id) and polls `wait/3` until someone answers in the UI or the question expires. Every
  agent-facing function is scoped by run id so one run can never read another's tickets.
  """
  import Ecto.Query

  alias Jarvis2.{Journal, Repo}
  alias Jarvis2.Questions.Question

  @topic "questions"
  @inbox_topic "inbox"
  @default_ttl_minutes 60
  @max_pending_per_run 5

  def topic, do: @topic

  @doc "Topic with a bare `:inbox_changed` message, for views that only show the pending count."
  def inbox_topic, do: @inbox_topic

  @doc "Creates a pending question for the run, or `{:error, :too_many}` when it has too many open."
  def ask(run_id, attrs) do
    expire_stale()

    pending =
      Repo.aggregate(
        from(q in Question, where: q.run_id == ^run_id and q.status == :pending),
        :count
      )

    if pending >= @max_pending_per_run do
      {:error, :too_many}
    else
      attrs =
        attrs
        |> Map.new()
        |> Map.put(:run_id, run_id)
        |> Map.put_new_lazy(:expires_at, fn ->
          DateTime.add(DateTime.utc_now(), @default_ttl_minutes * 60, :second)
        end)

      with {:ok, question} <- %Question{} |> Question.changeset(attrs) |> Repo.insert() do
        record(question, "question.asked")
        broadcast(question)
        {:ok, question}
      end
    end
  end

  @doc "A question of the given run, with lazy expiry. `nil` when the run does not own it."
  def get(id, run_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Question{run_id: ^run_id} = question <- Repo.get(Question, uuid) do
      expire_if_due(question)
    else
      _ -> nil
    end
  end

  def get(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id), %Question{} = question <- Repo.get(Question, uuid) do
      expire_if_due(question)
    end
  end

  @doc "Waits up to `timeout_ms` for the question to leave `:pending`; returns its current state."
  def wait(id, run_id, timeout_ms) do
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "question:" <> id)

    try do
      case get(id, run_id) do
        %Question{status: :pending} ->
          receive do
            {:question, %Question{id: ^id}} -> get(id, run_id)
          after
            timeout_ms -> get(id, run_id)
          end

        other ->
          other
      end
    after
      Phoenix.PubSub.unsubscribe(Jarvis2.PubSub, "question:" <> id)
    end
  end

  @doc "Records the human's answer. Exactly one answer is accepted per question."
  def answer(%Question{} = question, answer) when is_binary(answer) do
    answer = String.trim(answer)

    if valid_answer?(question, answer) do
      record_answer(question, answer)
    else
      {:error, :invalid_answer}
    end
  end

  defp record_answer(question, answer) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(q in Question,
          where: q.id == ^question.id and q.status == :pending and q.expires_at > ^now
        ),
        set: [status: :answered, answer: answer, answered_at: now, updated_at: now]
      )

    if count == 1 do
      answered = Repo.get!(Question, question.id)
      record(answered, "question.answered")
      broadcast(answered)
      {:ok, answered}
    else
      {:error, :not_pending}
    end
  end

  def list_pending do
    expire_stale()
    Repo.all(from q in Question, where: q.status == :pending, order_by: q.inserted_at)
  end

  def list_for_run(run_id, status \\ :pending) do
    Repo.all(
      from q in Question,
        where: q.run_id == ^run_id and q.status == ^status,
        order_by: q.inserted_at
    )
  end

  def pending_count, do: Repo.aggregate(from(q in Question, where: q.status == :pending), :count)

  @doc "Cancels everything still open for a run that has ended."
  def cancel_for_run(run_id),
    do:
      close_where(
        from(q in Question, where: q.run_id == ^run_id and q.status == :pending),
        :cancelled
      )

  @doc "Marks questions past their deadline as expired."
  def expire_stale do
    now = DateTime.utc_now()

    close_where(
      from(q in Question, where: q.status == :pending and q.expires_at <= ^now),
      :expired
    )
  end

  defp expire_if_due(%Question{status: :pending, expires_at: expires_at} = question) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
      question
    else
      close_where(
        from(q in Question, where: q.id == ^question.id and q.status == :pending),
        :expired
      )

      Repo.get!(Question, question.id)
    end
  end

  defp expire_if_due(question), do: question

  defp close_where(query, status) do
    now = DateTime.utc_now()
    ids = Repo.all(from(q in query, select: q.id))

    if ids != [] do
      Repo.update_all(from(q in Question, where: q.id in ^ids and q.status == :pending),
        set: [status: status, updated_at: now]
      )

      for question <- Repo.all(from q in Question, where: q.id in ^ids) do
        record(question, "question." <> Atom.to_string(status))
        broadcast(question)
      end
    end

    length(ids)
  end

  defp valid_answer?(%Question{kind: :approval}, answer), do: answer in ["approve", "deny"]
  defp valid_answer?(%Question{options: [_ | _] = options}, answer), do: answer in options
  defp valid_answer?(_question, answer), do: byte_size(answer) in 1..2_000

  defp broadcast(question) do
    for topic <- [@topic, "run:" <> question.run_id, "question:" <> question.id] do
      Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, topic, {:question, question})
    end

    Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, @inbox_topic, :inbox_changed)
  end

  defp record(question, type) do
    Journal.record(%{
      source: :mcp,
      type: type,
      run_id: question.run_id,
      payload: %{question_id: question.id, kind: question.kind, status: question.status}
    })
  end
end
