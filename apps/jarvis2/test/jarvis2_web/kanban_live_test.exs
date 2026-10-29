defmodule Jarvis2Web.KanbanLiveTest do
  use Jarvis2Web.ConnCase, async: false
  alias Jarvis2.{Kanban, Repo, Runs}

  setup %{conn: conn}, do: %{conn: sign_in(conn)}

  test "requires a session and adds cards", %{conn: conn} do
    anonymous = Phoenix.ConnTest.build_conn() |> Map.put(:host, "127.0.0.1")
    assert redirected_to(get(anonymous, "/kanban")) == "/login"
    {:ok, view, _} = live(conn, "/kanban")
    view |> form("#card-form", card: %{title: "New idea", cwd: File.cwd!()}) |> render_submit()
    assert has_element?(view, ".kanban-card", "New idea")
    {:ok, card} = Kanban.create_card(%{title: "Elsewhere", cwd: File.cwd!()})
    assert has_element?(view, "#card-#{card.id}", "Elsewhere")
    render_hook(view, "move_card", %{id: card.id, to: "done"})
    assert_reply view, %{ok: false}
    assert Kanban.get_card(card.id).column == :scratch
  end

  test "chooses a kind, shows its badge and copies a finished deliverable", %{conn: conn} do
    {:ok, view, _} = live(conn, "/kanban")

    view
    |> form("#card-form", card: %{title: "Ticket", cwd: File.cwd!(), kind: "refine"})
    |> render_change()

    assert render(view) =~ "Paste the Jira ticket text"

    view
    |> form("#card-form", card: %{title: "Ticket", cwd: File.cwd!(), kind: "refine"})
    |> render_submit()

    [card] = Kanban.list_cards()
    assert card.kind == :refine
    assert has_element?(view, "#card-#{card.id}[data-kind=refine] .kind-badge", "Refine")

    {:ok, run} = Runs.create_run(%{name: "ticket", task: "test", cwd: card.cwd})
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
    {:ok, _} = Kanban.submit_deliverable(run.id, "Goal: useful")
    {:ok, detail, _} = live(conn, "/kanban/cards/#{card.id}")
    assert has_element?(detail, "#deliverable-#{card.id}[phx-hook=Copy] button", "Copy")
    assert has_element?(detail, "#deliverable-#{card.id} pre", "Goal: useful")
  end

  test "does not log card ideas entered in LiveView", %{conn: conn} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, view, _} = live(conn, "/kanban")

        view
        |> form("#card-form",
          card: %{title: "secret title", body: "secret idea", cwd: File.cwd!()}
        )
        |> render_submit()
      end)

    refute log =~ "secret"
  end

  test "drafts recommendations, reloads, and submits the round", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{name: "planner", cwd: File.cwd!(), task: "test"})
    {:ok, card} = Kanban.create_card(%{title: "Idea", cwd: File.cwd!()})
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

    {:ok, round} =
      Kanban.ask_questions(run.id, [
        %{title: "First", body: "Details", recommended: "Yes", options: ["No"]},
        %{title: "Second", body: "More", recommended: "Maybe"}
      ])

    {:ok, view, html} = live(conn, "/kanban/cards/#{card.id}/answer")
    assert html =~ "First"
    assert html =~ "Second"
    assert has_element?(view, "#submit-answers[disabled]")
    view |> element("#accept-Q1") |> render_click()
    assert Kanban.get_round(round.id).answers["Q1"]["text"] == "Yes"
    {:ok, view, _} = live(conn, "/kanban/cards/#{card.id}/answer")
    assert render(view) =~ "Answered"
    view |> element("#accept-all") |> render_click()
    refute has_element?(view, "#submit-answers[disabled]")
    view |> form("#answer-form") |> render_submit()

    assert_eventually(fn ->
      Jarvis2.Journal.count(type: "kanban.delivery", run_id: run.id) > 0
    end)

    assert Kanban.get_card(card.id).column == :agent
    assert Kanban.get_round(round.id).status == :answered
  end

  test "shows and selects alternatives, with a custom answer when none are provided", %{
    conn: conn
  } do
    {:ok, run} = Runs.create_run(%{name: "planner", cwd: File.cwd!(), task: "test"})
    {:ok, card} = Kanban.create_card(%{title: "Idea", cwd: File.cwd!()})
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

    {:ok, round} =
      Kanban.ask_questions(run.id, [
        %{title: "Choose", body: "Details", recommended: "Yes", options: ["No", "Maybe"]},
        %{title: "Open", body: "Details", recommended: "Default"}
      ])

    {:ok, view, _} = live(conn, "/kanban/cards/#{card.id}/answer")
    assert has_element?(view, ~s([data-question="Q1"] button[aria-pressed="false"]), "No")
    assert has_element?(view, ~s([data-question="Q1"] button[aria-pressed="false"]), "Maybe")
    assert has_element?(view, ~s([data-question="Q2"]), "No alternatives provided")
    assert has_element?(view, ~s([data-question="Q2"] label), "Or write your own answer")

    view |> element(~s([data-question="Q1"] button), "No") |> render_click(%{"value" => ""})
    assert Kanban.get_round(round.id).answers["Q1"]["text"] == "No"
    assert has_element?(view, ~s([data-question="Q1"] button[aria-pressed="true"]), "No")

    view |> element(~s([data-question="Q1"] button), "Maybe") |> render_click(%{"value" => ""})
    assert Kanban.get_round(round.id).answers["Q1"]["text"] == "Maybe"
    assert has_element?(view, ~s([data-question="Q1"] button[aria-pressed="true"]), "Maybe")
    assert has_element?(view, ~s([data-question="Q1"] button[aria-pressed="false"]), "No")

    {:ok, reloaded, _} = live(conn, "/kanban/cards/#{card.id}/answer")
    assert has_element?(reloaded, ~s([data-question="Q1"] button[aria-pressed="true"]), "Maybe")
    reloaded |> element("#accept-Q1") |> render_click()
    assert has_element?(reloaded, ~s(#accept-Q1[aria-pressed="true"]))
    assert has_element?(reloaded, ~s([data-question="Q1"] button[aria-pressed="false"]), "Maybe")

    reloaded
    |> form("#answer-form")
    |> render_change(%{
      "_target" => ["answers", "Q2", "text"],
      "answers" => %{
        "Q1" => %{"kind" => "recommended", "text" => "Yes", "note" => ""},
        "Q2" => %{"kind" => "", "text" => "Something else", "note" => ""}
      }
    })

    assert Kanban.get_round(round.id).answers["Q2"]["text"] == "Something else"
    assert Kanban.get_round(round.id).answers["Q2"]["kind"] == "custom"
    refute has_element?(reloaded, "#submit-answers[disabled]")
  end

  test "custom answers and notes survive reload and a cancelled round is reported", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{name: "planner", cwd: File.cwd!(), task: "test"})
    {:ok, card} = Kanban.create_card(%{title: "Idea", cwd: File.cwd!()})
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()

    {:ok, round} =
      Kanban.ask_questions(run.id, [
        %{title: "Choose", body: "Details", recommended: "Yes", options: ["No"]}
      ])

    {:ok, view, _} = live(conn, "/kanban/cards/#{card.id}/answer")
    # The real client adds the button's own empty "value"; it must not clobber the option.
    view |> element("button", "No") |> render_click(%{"value" => ""})
    assert Kanban.get_round(round.id).answers["Q1"]["kind"] == "option"
    assert Kanban.get_round(round.id).answers["Q1"]["text"] == "No"

    view
    |> form("#answer-form")
    |> render_change(%{
      "_target" => ["answers", "Q1", "text"],
      "answers" => %{
        "Q1" => %{"kind" => "option", "text" => "A custom choice", "note" => "because"}
      }
    })

    assert Kanban.get_round(round.id).answers["Q1"] == %{
             "kind" => "custom",
             "text" => "A custom choice",
             "note" => "because"
           }

    {:ok, reloaded, _} = live(conn, "/kanban/cards/#{card.id}/answer")
    assert has_element?(reloaded, ~s(input[value="A custom choice"]))
    assert has_element?(reloaded, ~s(input[value="because"]))
    {:ok, _} = Kanban.submit_deliverable(run.id, "plan")
    assert has_element?(reloaded, "#card-panel", "This round is no longer open.")
  end

  test "dropping a done card opens reopen without moving it", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{name: "planner", cwd: File.cwd!(), task: "test"})
    {:ok, card} = Kanban.create_card(%{title: "Idea", cwd: File.cwd!()})
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
    {:ok, _} = Kanban.submit_deliverable(run.id, "plan text")
    {:ok, view, _} = live(conn, "/kanban")
    render_hook(view, "move_card", %{id: card.id, to: "agent"})
    assert_reply view, %{ok: true}
    assert_patch(view, "/kanban/cards/#{card.id}/reopen")
    assert Kanban.get_card(card.id).column == :done
    assert render(view) =~ "plan text"
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
