defmodule Jarvis2.KanbanTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.{Journal, Kanban, Runs}
  alias Jarvis2.Kanban.Card

  defp build_prompt(card, rounds, feedback \\ nil, opts \\ []) do
    {:ok, role} = Jarvis2.Roles.get(Jarvis2.Kanban.Kind.stage(card.kind, card.stage).role)
    Jarvis2.Kanban.Prompt.build(card, rounds, feedback, Keyword.put(opts, :role, role))
  end

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

  test "scratch cards can be archived without a run" do
    assert {:ok, archived} = Kanban.move(card(), :archive)
    assert archived.column == :archive
    assert archived.run_id == nil
    assert {:error, "Restore an archived card with a reason."} = Kanban.move(archived, :scratch)
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

  test "worktree defaults, validates, trims and cannot be changed" do
    assert card().worktree == "main"
    attrs = %{title: "x", cwd: File.cwd!()}

    for bad <- ["", "   ", "-bad", "a..b", "a b", "a/", "a.lock", String.duplicate("x", 101)] do
      assert {:error, changeset} = Kanban.create_card(Map.put(attrs, :worktree, bad))
      assert changeset.errors[:worktree]
    end

    assert {:ok, card} = Kanban.create_card(Map.put(attrs, :worktree, "  feature/x  "))
    assert card.worktree == "feature/x"
    assert {:error, _} = card |> Card.changeset(%{worktree: "other"}) |> Repo.update()
    assert Kanban.get_card(card.id).worktree == "feature/x"
  end

  test "card kinds have independent input and question limits" do
    assert card().kind == :plan

    for kind <- [:plan, :research, :explain, :review, :refine, :slides, :architecture] do
      limit = if kind == :plan, do: 2_000, else: 4_000

      attrs = %{
        title: "Example",
        cwd: File.cwd!(),
        kind: kind,
        body: String.duplicate("x", limit)
      }

      assert {:ok, card} = Kanban.create_card(attrs)
      assert card.kind == kind
      assert {:error, _} = Kanban.create_card(%{attrs | body: String.duplicate("x", limit + 1)})
    end

    assert {:error, _} = Kanban.create_card(%{title: "x", cwd: File.cwd!(), kind: "unknown"})

    for {kind, max} <- [
          plan: 8,
          research: 4,
          explain: 2,
          review: 3,
          refine: 4,
          slides: 4,
          architecture: 3
        ] do
      {:ok, card} = Kanban.create_card(%{title: "x", cwd: File.cwd!(), kind: kind})
      {:ok, run} = Runs.create_run(%{name: "test", task: "test", cwd: card.cwd})
      card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
      assert {:error, _} = Kanban.ask_questions(run.id, List.duplicate(question(), max + 1))
      assert {:ok, _} = Kanban.ask_questions(run.id, List.duplicate(question(), max))
    end
  end

  test "stages are assigned by kind and cannot be supplied by the caller" do
    for kind <- Jarvis2.Kanban.Kind.creatable() do
      {:ok, card} =
        Kanban.create_card(%{title: "x", cwd: File.cwd!(), kind: kind, stage: :implementation})

      assert card.stage == if(kind == :plan, do: :planning, else: :main)
    end
  end

  test "prompts contain only role instructions and card context" do
    card = card()
    role = %Jarvis2.Roles.Role{prompt: "Do the role's work."}
    task = Jarvis2.Kanban.Prompt.build(card, [], nil, role: role)
    assert task =~ "Do the role's work.\n\n## Working with the human\n\n"
    assert task =~ "\n\nCard: Private idea\nIdea: Private body"
    assert Jarvis2.Runs.Prompt.build(%{name: "label", task: task}) == task
    for tool <- ~w(ask_human request_approval submit_result), do: refute(task =~ tool)
    assert Jarvis2.Runs.Prompt.build(%{task: "  unmodified task\n"}) == "  unmodified task\n"
  end

  test "skill reports are validated and grouped by stage" do
    {card, run} = agent_card()

    for {name, reason} <- [
          {"", "x"},
          {"x", "  "},
          {String.duplicate("é", 51), "x"},
          {"x", String.duplicate("é", 251)}
        ] do
      assert {:error, _} = Kanban.report_skill(run.id, name, reason)
    end

    assert {:ok, _} = Kanban.report_skill(run.id, "planning-skill", "Plan")
    card |> Ecto.Changeset.change(stage: :implementation) |> Repo.update!()
    assert {:ok, _} = Kanban.report_skill(run.id, "coding-skill", "Implement")

    assert Enum.map(Kanban.get_card(card.id).skill_uses, &{&1.stage, &1.name}) == [
             {:planning, "planning-skill"},
             {:implementation, "coding-skill"}
           ]

    assert {:ok, _} =
             Kanban.report_skill(run.id, String.duplicate("é", 50), String.duplicate("é", 250))
  end

  test "skill report cap is atomic and applies independently per stage" do
    {card, run} = agent_card()
    for n <- 1..49, do: assert({:ok, _} = Kanban.report_skill(run.id, "skill-#{n}", "needed"))

    results =
      1..2
      |> Task.async_stream(fn n -> Kanban.report_skill(run.id, "last-#{n}", "needed") end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 1
    assert length(Kanban.get_card(card.id).skill_uses) == 50
    card |> Ecto.Changeset.change(stage: :implementation) |> Repo.update!()
    assert {:ok, _} = Kanban.report_skill(run.id, "new-stage", "needed")
  end

  test "implementation prompts omit planning context and refer to PLAN.md" do
    card = %{
      card()
      | stage: :implementation,
        accepted_plan: String.duplicate("secret plan", 2_000),
        deliverable: "old report"
    }

    round = %Jarvis2.Kanban.Round{
      number: 1,
      status: :answered,
      questions: [%{"id" => "Q1", "title" => "Planning secret"}],
      answers: %{"Q1" => %{"kind" => "custom", "text" => "secret", "note" => ""}}
    }

    prompt = build_prompt(card, [round])
    assert prompt =~ "PLAN.md"
    assert prompt =~ "implementation report"
    refute prompt =~ "Do not edit files"
    refute prompt =~ "Planning secret"
    refute prompt =~ "secret plan"
    refute prompt =~ "old report"
    assert byte_size(prompt) <= 65_536

    started = DateTime.utc_now()
    planning = %{round | inserted_at: DateTime.add(started, -1, :second)}

    implementation = %{
      round
      | inserted_at: DateTime.add(started, 1, :second),
        questions: [%{"id" => "Q1", "title" => "Implementation decision"}]
    }

    card = %{
      card
      | stage_started_at: started,
        feedback: [
          %Jarvis2.Kanban.Feedback{
            text: "old planning feedback",
            inserted_at: DateTime.add(started, -1, :second)
          },
          %Jarvis2.Kanban.Feedback{
            text: "implementation feedback",
            inserted_at: DateTime.add(started, 1, :second)
          }
        ]
    }

    restored =
      build_prompt(card, [planning, implementation], "continue", restored: true)

    assert restored =~ "Implementation decision"
    assert restored =~ "implementation feedback"
    refute restored =~ "Planning secret"
    refute restored =~ "old planning feedback"
    assert byte_size(restored) <= 65_536
    assert Jarvis2.Kanban.Prompt.reopen("fix", :plan, :implementation) =~ "implementation report"
    assert Jarvis2.Kanban.Prompt.answers(round, :implementation) =~ "implementation report"
  end

  test "a persisted card cannot change kind" do
    card = card()
    changeset = Card.changeset(card, %{kind: :review})
    assert {:error, _} = Repo.update(changeset)
    assert Kanban.get_card(card.id).kind == :plan
  end

  test "deliverables enforce per-kind limits and can finish without questions" do
    {:ok, card} = Kanban.create_card(%{title: "x", cwd: File.cwd!(), kind: :refine})
    {:ok, run} = Runs.create_run(%{name: "test", task: "test", cwd: card.cwd})
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
    assert {:error, message} = Kanban.submit_deliverable(run.id, String.duplicate("x", 4_001))
    assert message =~ "4000"
    assert {:ok, _} = Kanban.submit_deliverable(run.id, "Result")
    assert %{column: :done, deliverable: "Result"} = Kanban.get_card(card.id)

    {_card, plan_run} = agent_card()
    assert {:ok, _} = Kanban.submit_deliverable(plan_run.id, String.duplicate("p", 20_000))
  end

  test "slides validate deliverables and keep deck HTML out of bounded prompts" do
    {:ok, card} =
      Kanban.create_card(%{
        title: "Deck",
        cwd: File.cwd!(),
        kind: :slides,
        body: String.duplicate("b", 4_000)
      })

    assert card.stage == :main
    {:ok, run} = Runs.create_run(%{name: "test", task: "test", cwd: card.cwd})
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
    assert {:error, _} = Kanban.submit_deliverable(run.id, "# markdown")
    assert {:error, message} = Kanban.submit_deliverable(run.id, String.duplicate("x", 200_001))
    assert message =~ "200000"
    assert Kanban.get_card(card.id).column == :agent

    html =
      "<!doctype html><html><head></head><body>" <>
        String.duplicate("z", 10_000) <> "</body></html>"

    assert {:ok, _} = Kanban.submit_deliverable(run.id, html)
    card = Kanban.get_card(card.id)
    assert card.column == :done
    prompt = build_prompt(card, [], String.duplicate("f", 1_000), restored: true)
    assert byte_size(prompt) <= 65_536
    assert prompt =~ Jarvis2.Kanban.Slides.path(card.id)
    refute prompt =~ html
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
    assert {:ok, _} = Kanban.submit_deliverable(run.id, "Private plan")
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

  test "delivers a complete round exceeding the former prompt cap without losing drafts" do
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
    assert byte_size(Jarvis2.Kanban.Prompt.answers(round)) > 6_000
    assert {:ok, _} = Kanban.submit_answers(round)
    assert_eventually(fn -> Journal.count(type: "kanban.delivery", run_id: run.id) > 0 end)
    assert Kanban.get_card(card.id).column == :agent
    assert Kanban.get_round(round.id).answers == answers
  end

  test "answers and feedback with forbidden controls are rejected without a transition" do
    {card, run} = agent_card()
    {:ok, round} = Kanban.ask_questions(run.id, [question()])

    {:ok, round} =
      Kanban.save_draft(round, %{"Q1" => %{"kind" => "custom", "text" => "bad\u0001answer"}})

    assert {:error, "Answers are invalid or too long" <> _} = Kanban.submit_answers(round)
    assert Kanban.get_card(card.id).column == :awaiting_user

    {:ok, _} = Kanban.submit_deliverable(run.id, "result")
    done = Kanban.get_card(card.id)

    assert {:error, "Feedback produces an invalid" <> _} =
             Kanban.reopen(done, "bad\u0001feedback")

    assert Kanban.get_card(card.id).column == :done
  end

  test "replacement prompts stay within the task budget" do
    card = card()
    huge = String.duplicate("é", 10_000)

    card = %{
      card
      | title: String.duplicate("t", 120),
        body: String.duplicate("b", 2_000),
        deliverable: huge
    }

    round = %Jarvis2.Kanban.Round{
      number: 1,
      status: :answered,
      questions: [%{"id" => "Q1", "title" => "Decision", "recommended" => "yes"}],
      answers: %{"Q1" => %{"kind" => "recommended", "text" => "yes", "note" => ""}}
    }

    prompt = build_prompt(card, [round], String.duplicate("f", 1_000))
    assert byte_size(prompt) <= 65_536
    assert String.valid?(prompt)
    assert prompt =~ "Decision"
    refute Jarvis2.Kanban.Prompt.answers(round) =~ "Chat output stays minimal."
  end

  test "kind prompts keep the card and feedback within the task limit" do
    for {kind, level, heading} <- [
          {:plan, "HEAVY", "`requirements-engineering`"},
          {:research, "MEDIUM", "`research`"},
          {:explain, "LIGHT", "`explain-change`"},
          {:review, "LIGHT", "`code-review`"},
          {:refine, "MEDIUM", "Acceptance criteria"},
          {:architecture, "MEDIUM", "`improve-codebase-architecture`"}
        ] do
      max = Jarvis2.Kanban.Kind.get(kind).max_body
      body = String.duplicate("b", max)
      feedback = String.duplicate("f", 1_000)

      card = %{
        card()
        | kind: kind,
          stage: Jarvis2.Kanban.Kind.initial_stage(kind),
          title: String.duplicate("t", 120),
          body: body,
          deliverable: String.duplicate("é", 10_000)
      }

      round = %Jarvis2.Kanban.Round{
        number: 1,
        status: :answered,
        questions: [%{"id" => "Q1", "title" => String.duplicate("q", 120)}],
        answers: %{
          "Q1" => %{"kind" => "custom", "text" => String.duplicate("a", 500), "note" => ""}
        }
      }

      prompt = build_prompt(card, [round], feedback)
      assert byte_size(prompt) <= 65_536
      assert prompt =~ body
      assert prompt =~ feedback
      assert prompt =~ level
      assert prompt =~ heading
      assert prompt =~ "Keep chat output minimal"
      assert String.valid?(prompt)
      restored = build_prompt(card, [round], feedback, restored: true)
      assert byte_size(restored) <= 65_536
      assert restored =~ "Restored from archive"
      assert restored =~ feedback
      assert String.valid?(restored)
      reopened = Jarvis2.Kanban.Prompt.reopen(feedback, kind)
      assert reopened =~ Jarvis2.Kanban.Kind.noun(kind)
      refute reopened =~ "Chat output stays minimal."
    end
  end

  test "only optional history is truncated, preserving mandatory multibyte content" do
    card = %{
      card()
      | body: String.duplicate("é", 1_000),
        deliverable: String.duplicate("界", 20_000)
    }

    role = %Jarvis2.Roles.Role{name: "custom", prompt: String.duplicate("p", 58_000)}
    feedback = String.duplicate("f", 1_000)
    task = Jarvis2.Kanban.Prompt.build(card, [], feedback, role: role)
    text = Jarvis2.Runs.Prompt.build(%{name: card.title, task: task})
    assert byte_size(text) <= 65_536
    assert String.valid?(text)
    assert text =~ role.prompt
    assert text =~ card.body
    assert text =~ feedback
    assert text =~ "Previous plan:"
    refute text =~ card.deliverable
  end

  test "requires feedback to reopen and preserves a done card when Herdr is unavailable" do
    {card, run} = agent_card()
    {:ok, _} = Kanban.submit_deliverable(run.id, "plan")
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
    assert {:error, _} = Kanban.submit_deliverable(Ecto.UUID.generate(), "plan")
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
