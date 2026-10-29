defmodule Jarvis2Web.InboxLiveTest do
  use Jarvis2Web.ConnCase, async: false

  alias Jarvis2.{Questions, Runs}

  setup %{conn: conn} do
    {:ok, one} = Runs.create_run(%{name: "alpha", task: "t", cwd: File.cwd!()})
    {:ok, two} = Runs.create_run(%{name: "beta", task: "t", cwd: File.cwd!()})
    %{conn: sign_in(conn), one: one, two: two}
  end

  test "requires a session" do
    conn = Phoenix.ConnTest.build_conn() |> Map.put(:host, "127.0.0.1")
    assert redirected_to(get(conn, "/inbox")) == "/login"
  end

  test "shows an empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, "/inbox")
    assert html =~ "Nothing is waiting for you."
    refute has_element?(view, "#inbox-count")
  end

  test "lists questions from every run and answers an option question", ctx do
    {:ok, q1} =
      Questions.ask(ctx.one.id, %{
        kind: :question,
        prompt: "Which file?",
        options: ["a.ex", "b.ex"]
      })

    {:ok, _q2} = Questions.ask(ctx.two.id, %{kind: :question, prompt: "Why?"})

    {:ok, view, html} = live(ctx.conn, "/inbox")
    assert html =~ "alpha"
    assert html =~ "beta"
    assert has_element?(view, "#inbox-count", "2")

    view |> element("#question-#{q1.id} button", "b.ex") |> render_click()

    assert %{status: :answered, answer: "b.ex"} = Questions.get(q1.id)
    refute has_element?(view, "#question-#{q1.id}")
    assert has_element?(view, "#inbox-count", "1")
  end

  test "answers free-text questions and approvals", ctx do
    {:ok, open} = Questions.ask(ctx.one.id, %{kind: :question, prompt: "Why?"})

    {:ok, approval} =
      Questions.ask(ctx.one.id, %{
        kind: :approval,
        prompt: "rm build/",
        options: ["approve", "deny"],
        detail: "frees space"
      })

    {:ok, view, html} = live(ctx.conn, "/inbox")
    assert html =~ "frees space"

    view
    |> form("#question-#{open.id} form", %{"answer" => "  because  "})
    |> render_submit()

    assert %{answer: "because"} = Questions.get(open.id)

    view |> element("#question-#{approval.id} button", "deny") |> render_click()
    assert %{answer: "deny", status: :answered} = Questions.get(approval.id)
  end

  test "agent-written text is escaped", ctx do
    {:ok, _} =
      Questions.ask(ctx.one.id, %{
        kind: :question,
        prompt: "<script>alert(1)</script>",
        options: ["<b>x</b>"]
      })

    {:ok, _view, html} = live(ctx.conn, "/inbox")
    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<b>x</b>"
  end

  test "a question closed elsewhere is reported instead of crashing", ctx do
    {:ok, q} = Questions.ask(ctx.one.id, %{kind: :question, prompt: "late", options: ["go"]})
    {:ok, view, _} = live(ctx.conn, "/inbox")

    # Answered through another session after this page rendered.
    {:ok, _} = Questions.answer(q, "go")
    render_click(view, "answer", %{"id" => q.id, "answer" => "go"})
    assert render(view) =~ "already closed"
    render_click(view, "answer", %{"id" => Ecto.UUID.generate(), "answer" => "go"})
    assert render(view) =~ "no longer exists"
  end

  test "the nav badge follows new questions on any page", ctx do
    {:ok, view, _} = live(ctx.conn, "/runs")
    refute has_element?(view, "#inbox-count")

    {:ok, _} = Questions.ask(ctx.one.id, %{kind: :question, prompt: "ping"})
    assert has_element?(view, "#inbox-count", "1")
  end

  test "the run page shows its own pending questions and updates live", ctx do
    {:ok, other} = Questions.ask(ctx.two.id, %{kind: :question, prompt: "not for alpha"})
    {:ok, view, html} = live(ctx.conn, "/runs/#{ctx.one.id}")
    refute html =~ "Waiting for you"

    {:ok, q} =
      Questions.ask(ctx.one.id, %{
        kind: :approval,
        prompt: "deploy?",
        options: ["approve", "deny"]
      })

    assert has_element?(view, "#question-#{q.id}", "deploy?")
    refute has_element?(view, "#question-#{other.id}")

    view |> element("#question-#{q.id} button", "approve") |> render_click()
    refute has_element?(view, "#question-#{q.id}")
    assert %{answer: "approve"} = Questions.get(q.id)
  end
end
