defmodule Jarvis2Web.RunLiveTest do
  use Jarvis2Web.ConnCase, async: false

  alias Jarvis2.Runs
  alias Jarvis2.Runs.Run

  setup %{conn: conn} do
    previous =
      for key <- [:live, :live_scenarios],
          into: %{},
          do: {key, Application.fetch_env(:jarvis2, key)}

    Application.put_env(:jarvis2, :live, false)
    Application.put_env(:jarvis2, :live_scenarios, [])

    # A private guard keeps these launches out of the shared per-minute rate limit.
    guard = start_supervised!({Jarvis2.Herdr.ExecutionGuard, [name: nil]})
    previous_guard = Application.fetch_env(:jarvis2, :execution_guard)
    Application.put_env(:jarvis2, :execution_guard, guard)

    on_exit(fn ->
      case previous_guard do
        {:ok, v} -> Application.put_env(:jarvis2, :execution_guard, v)
        :error -> Application.delete_env(:jarvis2, :execution_guard)
      end

      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:jarvis2, key, v)
          :error -> Application.delete_env(:jarvis2, key)
        end
      end
    end)

    %{conn: sign_in(conn)}
  end

  test "pages require a session", %{conn: conn} do
    anonymous = Phoenix.ConnTest.build_conn() |> Map.put(:host, "127.0.0.1")

    for path <- ["/runs", "/runs/new", "/runs/#{Ecto.UUID.generate()}"] do
      assert redirected_to(get(anonymous, path)) == "/login"
    end

    assert is_binary(conn.host)
  end

  describe "index" do
    test "lists runs, filters by status and follows new runs", %{conn: conn} do
      {:ok, one} = Runs.create_run(%{name: "first", task: "t", cwd: File.cwd!()})
      {:ok, view, html} = live(conn, "/runs")
      assert html =~ "first"
      assert has_element?(view, "#run-#{one.id} .badge-starting")

      {:ok, two} = Runs.create_run(%{name: "second", task: "t", cwd: File.cwd!()})
      assert has_element?(view, "#run-#{two.id}")

      Runs.launch(two)
      assert has_element?(view, "#run-#{two.id} .badge-dry_run")

      {:ok, filtered, _} = live(conn, "/runs?status=dry_run")
      assert has_element?(filtered, "#run-#{two.id}")
      refute has_element?(filtered, "#run-#{one.id}")
    end

    test "shows an empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/runs")
      assert html =~ "No runs yet."
    end
  end

  describe "new" do
    test "prefills the Pi, luna and low defaults", %{conn: conn} do
      {:ok, view, html} = live(conn, "/runs/new")
      assert html =~ "Dry-run"

      assert has_element?(
               view,
               ~s(input[name="run[model]"][value="openrouter/openai/gpt-6-luna"])
             )

      assert has_element?(view, ~s(select[name="run[thinking]"] option[value="low"][selected]))
      assert has_element?(view, ~s(select[name="run[kind]"] option[value="pi"][selected]))
    end

    test "validates while typing and rejects an unsafe model", %{conn: conn} do
      {:ok, view, _} = live(conn, "/runs/new")

      html =
        view
        |> form("#run-form", run: %{model: "openrouter/x; rm -rf ~", name: "", task: ""})
        |> render_change()

      assert html =~ "must look like provider/model"
      assert html =~ "can&#39;t be blank"
    end

    test "a dry-run start creates the run and shows its plan", %{conn: conn} do
      {:ok, view, _} = live(conn, "/runs/new")

      {:ok, show, html} =
        view
        |> form("#run-form", run: %{name: "demo", task: "private task", cwd: File.cwd!()})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "demo"
      [run] = Runs.list_runs()
      assert run.name == "demo"

      # The launch runs in the background and ends in dry_run with the planned calls recorded.
      assert_eventually(fn -> has_element?(show, ".badge-dry_run") end)
      assert render(show) =~ "pane.split"
      assert render(show) =~ "agent.start"
      refute render(show) =~ "private task"
    end

    test "live mode without Herdr explains why start is disabled", %{conn: conn} do
      Application.put_env(:jarvis2, :live, true)
      Application.put_env(:jarvis2, :live_scenarios, [:agent_spawn, :agent_prompt])
      previous = Application.fetch_env(:jarvis2, :mirror)
      Application.put_env(:jarvis2, :mirror, :nonexistent_mirror)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:jarvis2, :mirror, v)
          :error -> Application.delete_env(:jarvis2, :mirror)
        end
      end)

      {:ok, view, _} = live(conn, "/runs/new")
      assert has_element?(view, "#unavailable", "Herdr is not connected")
      assert has_element?(view, ~s(button[type="submit"][disabled]))

      assert view |> form("#run-form", run: %{name: "x", task: "t"}) |> render_submit() =~
               "Herdr is not connected"

      assert Runs.list_runs() == []
    end
  end

  describe "show" do
    test "redirects when the run does not exist", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/runs"}}} =
               live(conn, "/runs/#{Ecto.UUID.generate()}")
    end

    test "streams timeline events and status changes as they happen", %{conn: conn} do
      {:ok, run} = Runs.create_run(%{name: "watch", task: "t", cwd: File.cwd!()})
      {:ok, view, html} = live(conn, "/runs/#{run.id}")
      assert html =~ "run.created"

      Runs.launch(run)
      assert has_element?(view, ".badge-dry_run")
      assert render(view) =~ "run.start"
    end

    test "a dry-run can be stopped from the page", %{conn: conn} do
      {:ok, run} = Runs.create_run(%{name: "stop me", task: "t", cwd: File.cwd!()})
      Runs.launch(run)
      {:ok, view, _} = live(conn, "/runs/#{run.id}")

      view |> element("#stop") |> render_click()
      assert has_element?(view, ".badge-stopped")
      assert %Run{status: :stopped} = Runs.get_run(run.id)
      refute has_element?(view, "#stop")
    end

    test "failed runs show their error", %{conn: conn} do
      {:ok, run} = Runs.create_run(%{name: "bad", task: "t", cwd: File.cwd!()})

      {:ok, run} =
        run
        |> Run.progress_changeset(%{status: :failed, result: %{error: "no pane"}})
        |> Jarvis2.Repo.update()

      {:ok, view, _} = live(conn, "/runs/#{run.id}")
      assert has_element?(view, "#run-error", "no pane")
    end
  end

  defp assert_eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(25) && assert_eventually(fun, attempts - 1)
    end
  end
end
