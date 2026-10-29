defmodule Jarvis2.KanbanTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.{Journal, Kanban, Runs}
  alias Jarvis2.Kanban.Card

  defp card do
    {:ok, card} =
      Kanban.create_card(%{title: "Private idea", body: "Private body", cwd: File.cwd!()})

    card
  end

  defp agent_card do
    card = card()
    {:ok, run} = Runs.create_run(%{name: "test", task: "test", cwd: card.cwd})
    {:ok, card} = card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update()
    {card, run}
  end

  defp question(title \\ "Private question") do
    %{
      title: title,
      body: "Private details",
      recommended: "Private recommendation",
      options: ["yes", "no"]
    }
  end

  test "creates and validates cards" do
    card = card()
    assert %Card{column: :scratch} = Kanban.get_card(card.id)
    assert [found] = Kanban.list_cards()
    assert found.id == card.id

    for attrs <- [
          %{title: ""},
          %{title: String.duplicate("x", 121)},
          %{cwd: "relative"},
          %{body: String.duplicate("x", 2001)}
        ] do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               Kanban.create_card(Map.merge(%{title: "x", cwd: File.cwd!()}, attrs))
    end
  end

  test "rounds are numbered across the card, save drafts and refuse incomplete answers" do
    {card, run} = agent_card()
    assert {:ok, round} = Kanban.ask_questions(run.id, [question(), question("Second")])
    assert Enum.map(round.questions, & &1["id"]) == ["Q1", "Q2"]
    assert Kanban.get_card(card.id).column == :awaiting_user
    assert {:error, _} = Kanban.ask_questions(run.id, [question()])
    assert {:error, _} = Kanban.submit_answers(round)

    answers = %{
      "Q1" => %{"kind" => "recommended", "text" => "Private recommendation", "note" => ""},
      "Q2" => %{"kind" => "option", "text" => "yes", "note" => ""}
    }

    assert {:ok, round} = Kanban.save_draft(round, answers)
    assert {:ok, _} = Kanban.submit_answers(round)
    assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) > 0 end)
    assert {:error, _} = Kanban.submit_answers(round)
    assert {:ok, next} = Kanban.ask_questions(run.id, [question()])
    assert hd(next.questions)["id"] == "Q3"
    assert {:ok, _} = Kanban.submit_plan(run.id, "Private plan")
    assert Kanban.get_card(card.id).column == :done
    assert Kanban.get_round(next.id).status == :cancelled
    refute inspect(Journal.recent()) =~ "Private"
  end

  test "rejects invalid questions and answers without changing state" do
    {card, run} = agent_card()

    for questions <- [
          [],
          List.duplicate(question(), 9),
          [question(String.duplicate("x", 121))],
          [Map.put(question(), :options, List.duplicate("x", 7))]
        ] do
      assert {:error, _} = Kanban.ask_questions(run.id, questions)
      assert Kanban.get_card(card.id).column == :agent
    end

    {:ok, round} = Kanban.ask_questions(run.id, [question()])

    assert {:error, _} =
             Kanban.save_draft(round, %{
               "Q1" => %{"kind" => "custom", "text" => String.duplicate("x", 501)}
             })

    assert Kanban.get_round(round.id).answers == %{}
  end

  test "rejects a complete round that exceeds the prompt cap without losing drafts" do
    {card, run} = agent_card()

    questions =
      List.duplicate(
        %{
          title: String.duplicate("t", 120),
          body: "body",
          recommended: String.duplicate("r", 500)
        },
        8
      )

    {:ok, round} = Kanban.ask_questions(run.id, questions)

    answers =
      Map.new(round.questions, fn question ->
        {question["id"],
         %{
           "kind" => "recommended",
           "text" => question["recommended"],
           "note" => String.duplicate("n", 500)
         }}
      end)

    {:ok, round} = Kanban.save_draft(round, answers)
    assert {:error, "Answers are too long" <> _} = Kanban.submit_answers(round)
    assert Kanban.get_card(card.id).column == :awaiting_user
    assert Kanban.get_round(round.id).answers == answers
  end

  test "replacement prompts stay within the task budget" do
    card = card()
    huge = String.duplicate("é", 10_000)

    card = %{
      card
      | title: String.duplicate("t", 120),
        body: String.duplicate("b", 2_000),
        plan: huge
    }

    round = %Jarvis2.Kanban.Round{
      number: 1,
      status: :answered,
      questions: [%{"id" => "Q1", "title" => "Decision", "recommended" => "yes"}],
      answers: %{"Q1" => %{"kind" => "recommended", "text" => "yes", "note" => ""}}
    }

    prompt = Jarvis2.Kanban.Prompt.build(card, [round], String.duplicate("f", 1_000))
    assert byte_size(prompt) <= 6_000
    assert String.valid?(prompt)
    assert prompt =~ "submit_plan"
    assert prompt =~ "Decision"
  end

  test "requires feedback to reopen and preserves a done card when Herdr is unavailable" do
    {card, run} = agent_card()
    {:ok, _} = Kanban.submit_plan(run.id, "plan")
    card = Kanban.get_card(card.id)
    assert {:error, _} = Kanban.move(card, :agent)
    assert {:error, _} = Kanban.reopen(card, "  ")
    assert {:error, _} = Kanban.reopen(card, String.duplicate("x", 1_001))
    old = Application.fetch_env(:jarvis2, :mirror)
    Application.put_env(:jarvis2, :mirror, :missing_kanban_mirror)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:jarvis2, :mirror, value)
        :error -> Application.delete_env(:jarvis2, :mirror)
      end
    end)

    assert {:error, "Herdr" <> _} = Kanban.reopen(card, "change it")
    assert Kanban.get_card(card.id).column == :done
  end

  test "refuses agent tools for other runs and invalid moves" do
    card = card()
    assert {:error, _} = Kanban.ask_questions(Ecto.UUID.generate(), [question()])
    assert {:error, _} = Kanban.submit_plan(Ecto.UUID.generate(), "plan")
    assert {:error, _} = Kanban.move(card, :done)
    assert Kanban.get_card(card.id).column == :scratch
  end

  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met")

      true ->
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
    end
  end
end
