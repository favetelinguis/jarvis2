defmodule Jarvis2.QuestionsTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.{Journal, Questions}

  setup do
    %{run: Ecto.UUID.generate(), other: Ecto.UUID.generate()}
  end

  test "asking stores a pending question, broadcasts it and journals without its text", %{
    run: run
  } do
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, Questions.topic())

    assert {:ok, q} =
             Questions.ask(run, %{
               kind: :question,
               prompt: "Which file?",
               options: ["a.ex", "b.ex"]
             })

    assert q.status == :pending
    assert_receive {:question, %{id: id}} when id == q.id
    assert [%{type: "question.asked", run_id: ^run}] = Journal.recent(run_id: run)
    refute inspect(Journal.recent()) =~ "Which file"
    assert Questions.pending_count() == 1
  end

  test "validates the question and bounds open questions per run", %{run: run} do
    assert {:error, %Ecto.Changeset{}} = Questions.ask(run, %{kind: :question, prompt: ""})

    assert {:error, %Ecto.Changeset{}} =
             Questions.ask(run, %{
               kind: :question,
               prompt: "x",
               options: [String.duplicate("o", 101)]
             })

    assert {:error, %Ecto.Changeset{}} = Questions.ask(run, %{kind: :bogus, prompt: "x"})

    for n <- 1..5, do: assert({:ok, _} = Questions.ask(run, %{kind: :question, prompt: "q#{n}"}))
    assert {:error, :too_many} = Questions.ask(run, %{kind: :question, prompt: "six"})
  end

  test "answers are checked against the options and accepted once", %{run: run} do
    {:ok, q} = Questions.ask(run, %{kind: :question, prompt: "pick", options: ["a", "b"]})
    assert {:error, :invalid_answer} = Questions.answer(q, "c")

    assert {:ok, %{status: :answered, answer: "b", answered_at: %DateTime{}}} =
             Questions.answer(q, " b ")

    assert {:error, :not_pending} = Questions.answer(q, "a")
    assert Questions.pending_count() == 0
  end

  test "approvals accept only approve or deny; open questions any non-empty text", %{run: run} do
    {:ok, approval} =
      Questions.ask(run, %{kind: :approval, prompt: "rm -rf build", options: ["approve", "deny"]})

    assert {:error, :invalid_answer} = Questions.answer(approval, "maybe")
    assert {:ok, %{answer: "deny"}} = Questions.answer(approval, "deny")

    {:ok, open} = Questions.ask(run, %{kind: :question, prompt: "why?"})
    assert {:error, :invalid_answer} = Questions.answer(open, "   ")
    assert {:ok, %{answer: "because"}} = Questions.answer(open, "because")
  end

  test "tickets are scoped to the run that asked", %{run: run, other: other} do
    {:ok, q} = Questions.ask(run, %{kind: :question, prompt: "mine"})
    assert %{id: id} = Questions.get(q.id, run)
    assert id == q.id
    assert Questions.get(q.id, other) == nil
    assert Questions.get("not-a-uuid", run) == nil
    assert Questions.wait(q.id, other, 10) == nil
  end

  test "wait returns as soon as the question is answered, or its state after the timeout", %{
    run: run
  } do
    {:ok, q} = Questions.ask(run, %{kind: :question, prompt: "wait", options: ["go"]})
    assert %{status: :pending} = Questions.wait(q.id, run, 30)

    waiter = Task.async(fn -> Questions.wait(q.id, run, 5_000) end)
    Process.sleep(50)
    {:ok, _} = Questions.answer(q, "go")
    assert %{status: :answered, answer: "go"} = Task.await(waiter, 1_000)
  end

  test "overdue questions expire lazily and in bulk", %{run: run} do
    past = DateTime.add(DateTime.utc_now(), -5, :second)
    {:ok, q} = Questions.ask(run, %{kind: :question, prompt: "late", expires_at: past})
    assert %{status: :expired} = Questions.get(q.id, run)
    assert {:error, :not_pending} = Questions.answer(q, "too late")

    {:ok, other} = Questions.ask(run, %{kind: :question, prompt: "late 2", expires_at: past})
    assert Questions.expire_stale() == 1
    assert %{status: :expired} = Questions.get(other.id, run)
  end

  test "cancel_for_run closes every open question of a finished run", %{run: run, other: other} do
    {:ok, a} = Questions.ask(run, %{kind: :question, prompt: "a"})
    {:ok, b} = Questions.ask(other, %{kind: :question, prompt: "b"})
    assert Questions.cancel_for_run(run) == 1
    assert %{status: :cancelled} = Questions.get(a.id, run)
    assert %{status: :pending} = Questions.get(b.id, other)
  end
end
