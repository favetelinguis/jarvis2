defmodule Jarvis2Web.KanbanLiveTest do
  use Jarvis2Web.ConnCase, async: false
  alias Jarvis2.{Kanban, Repo, Runs}

  defmodule Mirror do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(_), do: {:ok, %{stale: false, snapshot: %{}}}
    def handle_call(:get, _, state), do: {:reply, state, state}
    def handle_cast(:invalidate, state), do: {:noreply, state}
  end

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

  test "the add card form creates dependencies atomically", %{conn: conn} do
    {:ok, prerequisite} = Kanban.create_card(%{title: "Prerequisite", cwd: File.cwd!()})
    {:ok, _} = Kanban.create_card(%{title: "Other project", cwd: "/tmp"})
    {:ok, view, _} = live(conn, "/kanban")
    view |> form("#card-form", card: %{title: "Dependent", cwd: File.cwd!()}) |> render_change()
    assert has_element?(view, "#card-blocked-by option[value='#{prerequisite.id}']")
    refute has_element?(view, "#card-blocked-by option", "Other project")

    view
    |> form("#card-form",
      card: %{title: "Dependent", cwd: File.cwd!(), blocked_by: [prerequisite.id]}
    )
    |> render_submit()

    dependent = Enum.find(Kanban.list_cards(), &(&1.title == "Dependent"))
    assert {:blocked, [_]} = Kanban.dependency_state(dependent)
  end

  test "dependency badges and panel edit and freeze dependencies", %{conn: conn} do
    {:ok, a} = Kanban.create_card(%{title: "A", cwd: File.cwd!()})
    {:ok, b} = Kanban.create_card(%{title: "B", cwd: File.cwd!()})
    {:ok, _} = Kanban.add_dependency(a, b)
    {:ok, view, _} = live(conn, "/kanban/cards/#{a.id}")
    assert has_element?(view, "#card-#{a.id}", "Blocked · 1")
    assert has_element?(view, "#dependencies-#{a.id}", "B")
    refute has_element?(view, "#dependency-prerequisite option[value='#{a.id}']")
    view |> element("#dependencies-#{a.id} button", "Remove") |> render_click()
    refute has_element?(view, "#card-#{a.id}", "Blocked · 1")

    view
    |> form("#dependency-form", %{"blocked_by" => b.id, "needs" => "done"})
    |> render_submit()

    assert has_element?(view, "#card-#{a.id}", "Blocked · 1")
    render_hook(view, "move_card", %{id: a.id, to: "agent"})
    assert_reply view, %{ok: false}
    assert render(view) =~ "Blocked by: B (needs done)"
    a |> Ecto.Changeset.change(column: :agent) |> Repo.update!()
    Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, Kanban.topic(), {:card, a})

    assert has_element?(
             view,
             "#dependencies-#{a.id}",
             "Dependencies are frozen once a card starts"
           )

    refute has_element?(view, "#dependency-form")
    assert has_element?(view, "#card-#{a.id}", "Stale")
  end

  test "skill reports are grouped by stage and update the open panel", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{name: "planner", task: "test", cwd: File.cwd!()})
    {:ok, card} = Kanban.create_card(%{title: "Idea", cwd: File.cwd!()})
    card = card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
    {:ok, view, _} = live(conn, "/kanban/cards/#{card.id}")
    assert has_element?(view, "#skills-planning", "No skills reported")
    assert {:ok, _} = Kanban.report_skill(run.id, "planning", "Clarify scope")
    assert has_element?(view, "#skills-planning", "planning — Clarify scope")
    card |> Ecto.Changeset.change(stage: :implementation) |> Repo.update!()
    assert {:ok, _} = Kanban.report_skill(run.id, "coding", "Write tests")
    assert has_element?(view, "#skills-planning", "planning — Clarify scope")
    assert has_element?(view, "#skills-implementation", "coding — Write tests")
  end

  test "worktree form lists branches and remains usable when Herdr is unavailable", %{conn: conn} do
    path = Path.join(System.tmp_dir!(), "j2-ui-#{System.unique_integer([:positive])}.sock")
    parent = self()

    handler = fn request ->
      send(parent, {:worktree_request, request["params"]["cwd"]})

      if request["params"]["cwd"] == "/unavailable" do
        {:reply, %{error: %{code: "disconnected", message: "offline"}}}
      else
        {:reply,
         %{
           result: %{
             worktrees: [
               %{path: "/repo", branch: "master", is_linked_worktree: false},
               %{path: "/linked", branch: "feature/x", is_linked_worktree: true}
             ]
           }
         }}
      end
    end

    {:ok, _, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Jarvis2.Herdr.Socket, [name: nil, path: path]})
    old = Application.fetch_env(:jarvis2, :herdr_socket)
    Application.put_env(:jarvis2, :herdr_socket, socket)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)

      case old do
        {:ok, value} -> Application.put_env(:jarvis2, :herdr_socket, value)
        :error -> Application.delete_env(:jarvis2, :herdr_socket)
      end
    end)

    {:ok, view, _} = live(conn, "/kanban")
    render_async(view)
    assert has_element?(view, ~s(#card_worktree[value="main"]))
    assert has_element?(view, ~s(#worktree-options option[value="feature/x"]))
    assert render(view) =~ "Uses the main checkout"

    view
    |> form("#card-form", card: %{title: "test", cwd: File.cwd!(), worktree: "feature/x"})
    |> render_change()

    assert render(view) =~ "Opens existing worktree feature/x"

    view
    |> form("#card-form", card: %{title: "test", cwd: File.cwd!(), worktree: "new"})
    |> render_change()

    assert render(view) =~ "Creates worktree new on first run"

    view
    |> form("#card-form", card: %{title: "test", cwd: File.cwd!(), worktree: ""})
    |> render_change()

    assert has_element?(view, ".field-error", "can't be blank")

    view
    |> form("#card-form", card: %{title: "test", cwd: "/unavailable", worktree: "new"})
    |> render_change()

    render_async(view)
    assert render(view) =~ "Herdr unavailable; worktrees cannot be listed"

    view
    |> form("#card-form", card: %{title: "test", cwd: File.cwd!(), worktree: "new"})
    |> render_submit()

    assert hd(Kanban.list_cards()).worktree == "new"
    assert has_element?(view, ~s(#card_worktree[value="main"]))
  end

  test "card details retain their browser-controlled open state during form updates", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/kanban")

    assert has_element?(
             view,
             ~s(#card-form details[phx-mounted*="ignore_attrs"][phx-mounted*="open"])
           )

    attrs = %{title: "Idea", body: "An idea", cwd: File.cwd!(), kind: "refine"}
    view |> form("#card-form", card: attrs) |> render_change()

    assert has_element?(
             view,
             ~s(#card-form details[phx-mounted*="ignore_attrs"][phx-mounted*="open"])
           )

    assert has_element?(view, "#card_body", "An idea")
    assert has_element?(view, ~s(#card_cwd[value="#{File.cwd!()}"]))
    assert render(view) =~ "Paste the Jira ticket text"

    view |> form("#card-form", card: attrs) |> render_submit()
    assert [%{body: "An idea", cwd: cwd, kind: :refine}] = Kanban.list_cards()
    assert cwd == File.cwd!()
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

  test "accept plan is only shown for the planning deliverable and reports errors", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "jarvis2-ui-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, run} = Runs.create_run(%{name: "planner", task: "test", cwd: dir})
    {:ok, card} = Kanban.create_card(%{title: "Idea", cwd: dir})
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
    {:ok, view, _} = live(conn, "/kanban/cards/#{card.id}")
    refute has_element?(view, "button[phx-click=advance]")
    {:ok, _} = Kanban.submit_deliverable(run.id, "the plan")
    assert has_element?(view, "button[phx-click=advance]", "Accept plan")
    assert has_element?(view, ".stage-badge", "Planning")

    old = Application.fetch_env(:jarvis2, :mirror)
    old_socket = Application.fetch_env(:jarvis2, :herdr_socket)
    Application.put_env(:jarvis2, :herdr_socket, :missing_kanban_ui_socket)
    Application.put_env(:jarvis2, :mirror, :missing_kanban_ui_mirror)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:jarvis2, :mirror, value)
        :error -> Application.delete_env(:jarvis2, :mirror)
      end

      case old_socket do
        {:ok, value} -> Application.put_env(:jarvis2, :herdr_socket, value)
        :error -> Application.delete_env(:jarvis2, :herdr_socket)
      end
    end)

    view |> element("button[phx-click=advance]") |> render_click()
    assert render(view) =~ "Herdr is not connected"
    assert Kanban.get_card(card.id).column == :done
    {:ok, mirror} = start_supervised(Mirror)
    Application.put_env(:jarvis2, :mirror, mirror)
    view |> element("button[phx-click=advance]") |> render_click()
    assert Kanban.get_card(card.id).stage == :implementation
    assert has_element?(view, "[data-column=agent] .stage-badge", "Implementation")
    assert has_element?(view, "#card-panel", "Accepted plan")
    refute has_element?(view, "button[phx-click=advance]")
    assert File.read!(Path.join(dir, "PLAN.md")) == "the plan"
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

  test "slides preview remains stable across refresh and is available on reopen", %{conn: conn} do
    html = "<!doctype html><html><head></head><body>Secret deck</body></html>"
    {:ok, card} = Kanban.create_card(%{title: "Deck", kind: :slides, cwd: File.cwd!()})
    card = card |> Ecto.Changeset.change(column: :done, deliverable: html) |> Repo.update!()
    {:ok, view, _} = live(conn, "/kanban/cards/#{card.id}")
    src = "/kanban/cards/#{card.id}/slides?v=#{:erlang.phash2(html)}"

    assert has_element?(
             view,
             ~s([phx-hook="SlidesPreview"][phx-update="ignore"][data-url="#{src}"] iframe.slides-frame[sandbox="allow-scripts"])
           )

    refute has_element?(view, "iframe.slides-frame[src]")
    assert has_element?(view, ~s(a[href="/kanban/cards/#{card.id}/slides?download=1"]), "Save")
    refute has_element?(view, "#card-panel pre")
    refute render(view) =~ "Secret deck"
    refute render(view) =~ "allow-same-origin"
    Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, Kanban.topic(), {:card, card})
    assert has_element?(view, ~s([phx-hook="SlidesPreview"][data-url="#{src}"]))
    {:ok, reopen, _} = live(conn, "/kanban/cards/#{card.id}/reopen")
    assert has_element?(reopen, ~s([phx-hook="SlidesPreview"][data-url="#{src}"]))
    refute has_element?(reopen, "#card-panel pre")
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

  test "archive column and restore form enforce a reason", %{conn: conn} do
    {:ok, card} = Kanban.create_card(%{title: "Finished", cwd: File.cwd!()})
    card |> Ecto.Changeset.change(column: :done, deliverable: "result") |> Repo.update!()
    {:ok, view, _} = live(conn, "/kanban")

    for column <- ~w(scratch agent awaiting_user done archive),
        do: assert(has_element?(view, "[data-column=#{column}]"))

    render_hook(view, "move_card", %{id: card.id, to: "archive"})
    assert_reply view, %{ok: true}
    assert Kanban.get_card(card.id).column == :archive
    assert has_element?(view, "#card-#{card.id}", "no saved session")
    render_hook(view, "move_card", %{id: card.id, to: "scratch"})
    assert_reply view, %{ok: false}
    assert render(view) =~ "Restore an archived card with a reason"
    render_hook(view, "move_card", %{id: card.id, to: "agent"})
    assert_reply view, %{ok: true}
    assert_patch(view, "/kanban/cards/#{card.id}/reopen")
    assert has_element?(view, "#reopen-form button", "Restore")
    render_submit(view, "reopen", %{"feedback" => " "})
    assert render(view) =~ "Feedback is required"
    assert Kanban.get_card(card.id).column == :archive
  end

  test "agents file review shows the real diff and applies only fresh proposals", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "agents-ui-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "AGENTS.md"), "remove me\n")
    {:ok, card} = Kanban.create_card(%{title: "Audit", cwd: dir, kind: :agents_file})
    {:ok, run} = Runs.create_run(%{name: "writer", task: "test", cwd: dir})
    run |> Ecto.Changeset.change(status: :stopped) |> Repo.update!()
    card |> Ecto.Changeset.change(column: :agent, run_id: run.id) |> Repo.update!()
    assert :ok = Kanban.begin_agents_file_run(run.id, dir)
    proposal = Jason.encode!(%{content: "keep me\n", changes: []})
    assert {:ok, _} = Kanban.submit_deliverable(run.id, proposal)
    {:ok, view, _} = live(conn, "/kanban/cards/#{card.id}")
    assert has_element?(view, "#agents-file-review", "Removes 1 lines, adds 1")
    assert has_element?(view, ".diff-del", "-remove me")
    assert has_element?(view, ".diff-ins", "+keep me")
    assert has_element?(view, "#agents-file-review button", "Apply to #{dir}/AGENTS.md")
    File.write!(Path.join(dir, "AGENTS.md"), "outside\n")
    {:ok, stale, _} = live(conn, "/kanban/cards/#{card.id}")
    assert has_element?(stale, ".banner-warn", "changed")
    refute has_element?(stale, "#agents-file-review button", "Apply")
    view |> element("#agents-file-review button", "Apply") |> render_click()
    assert has_element?(view, ".banner-warn", "changed")
    refute has_element?(view, "#agents-file-review button", "Apply")
    assert Kanban.get_card(card.id).column == :done
    assert File.read!(Path.join(dir, "AGENTS.md")) == "outside\n"
    File.write!(Path.join(dir, "AGENTS.md"), "remove me\n")
    {:ok, fresh, _} = live(conn, "/kanban/cards/#{card.id}")
    fresh |> element("#agents-file-review button", "Apply") |> render_click()
    assert Kanban.get_card(card.id).column == :archive
    assert File.read!(Path.join(dir, "AGENTS.md")) == "keep me\n"
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
