defmodule Jarvis2Web.RunLiveTest do
  use Jarvis2Web.ConnCase, async: false

  alias Jarvis2.Runs
  alias Jarvis2.Runs.Run

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
    def handle_call({:put, view}, _from, _), do: {:reply, :ok, view}
    def handle_cast(:invalidate, view), do: {:noreply, view}
  end

  setup %{conn: conn} do
    previous =
      for key <- [:live_scenarios],
          into: %{},
          do: {key, Application.fetch_env(:jarvis2, key)}

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
      assert has_element?(view, "#run-#{two.id} .badge-failed")

      {:ok, filtered, _} = live(conn, "/runs?status=failed")
      assert has_element?(filtered, "#run-#{two.id}")
      refute has_element?(filtered, "#run-#{one.id}")
    end

    test "starts a Mix job from the page and shows its output", %{conn: conn} do
      dir = Path.join(System.tmp_dir!(), "mixui-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      fake = Path.join(dir, "fake-mix")
      File.write!(fake, "#!/bin/sh\necho \"all green\"\n")
      File.chmod!(fake, 0o700)

      for {key, value} <- [mix_project_dir: dir, mix_executable: fake] do
        old = Application.fetch_env(:jarvis2, key)
        Application.put_env(:jarvis2, key, value)

        on_exit(fn ->
          File.rm_rf!(dir)

          case old do
            {:ok, v} -> Application.put_env(:jarvis2, key, v)
            :error -> Application.delete_env(:jarvis2, key)
          end
        end)
      end

      {:ok, view, _} = live(conn, "/runs")
      view |> element("button", "mix test") |> render_click()

      assert_eventually(fn -> has_element?(view, "td .badge-done") end)
      [run] = Runs.list_runs()
      assert run.kind == "mix"

      {:ok, show, html} = live(conn, "/runs/#{run.id}")
      assert html =~ "all green"
      assert html =~ "exit status 0"
      refute has_element?(show, "#stop")
    end

    test "shows an empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/runs")
      assert html =~ "No runs yet."
    end
  end

  describe "new" do
    test "prefills the Pi, luna and low defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/runs/new")

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

    test "a start creates the run and sends it to Herdr", %{conn: conn} do
      start_fake_launcher()
      {:ok, view, _} = live(conn, "/runs/new")

      {:ok, show, html} =
        view
        |> form("#run-form", run: %{name: "demo", task: "private task", cwd: File.cwd!()})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "demo"
      [run] = Runs.list_runs()
      assert run.name == "demo"

      assert_eventually(fn -> has_element?(show, ".badge-working") end)
      assert_receive {:request, "pane.split"}
      assert_receive {:request, "agent.start"}
      assert_receive {:request, "agent.prompt"}
      assert render(show) =~ "run.start"
      refute render(show) =~ "private task"
    end

    test "live mode without Herdr explains why start is disabled", %{conn: conn} do
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
      assert has_element?(view, ".badge-failed")
      assert render(view) =~ "run.start"
    end

    test "opening and updating an active run does not read its pane", %{conn: conn} do
      pane = %{
        "pane_id" => "w1:p9",
        "terminal_id" => "term-run",
        "workspace_id" => "w1",
        "tab_id" => "w1:t1"
      }

      mirror =
        start_supervised!(
          {Mirror,
           %{
             stale: false,
             snapshot: %{"panes" => [pane], "agents" => [Map.put(pane, "agent", "pi")]}
           }}
        )

      path =
        Path.join(
          Application.fetch_env!(:jarvis2, :state_dir),
          "no-tail-#{System.unique_integer([:positive])}"
        )

      test_pid = self()

      {:ok, _, listener} =
        Jarvis2.Test.FakeHerdr.start_link(path, fn %{"method" => "pane.read"} ->
          send(test_pid, :pane_read)
          {:reply, %{result: %{type: "pane_read", read: %{pane_id: "w1:p9", text: "output"}}}}
        end)

      socket = start_supervised!({Jarvis2.Herdr.Socket, [name: nil, path: path]})
      on_exit(fn -> :gen_tcp.close(listener) end)

      for {key, value} <- [mirror: mirror, herdr_socket: socket] do
        old = Application.fetch_env(:jarvis2, key)
        Application.put_env(:jarvis2, key, value)

        on_exit(fn ->
          case old do
            {:ok, v} -> Application.put_env(:jarvis2, key, v)
            :error -> Application.delete_env(:jarvis2, key)
          end
        end)
      end

      {:ok, run} = Runs.create_run(%{name: "active", task: "t", cwd: File.cwd!()})

      {:ok, run} =
        run
        |> Run.progress_changeset(%{status: :working, pane_id: "w1:p9", terminal_id: "term-run"})
        |> Jarvis2.Repo.update()

      {:ok, view, _} = live(conn, "/runs/#{run.id}")
      assert has_element?(view, "#focus")
      refute_receive :pane_read, 300

      Phoenix.PubSub.broadcast(Jarvis2.PubSub, "run:" <> run.id, {:run, run})
      assert has_element?(view, ".badge-working")
      refute_receive :pane_read, 300
      refute has_element?(view, "h2", "Terminal")
    end

    test "a starting run without a pane can be stopped from the page", %{conn: conn} do
      {:ok, run} = Runs.create_run(%{name: "stop me", task: "t", cwd: File.cwd!()})
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

  defp start_fake_launcher do
    anchor = %{
      "pane_id" => "w1:p1",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "terminal_id" => "anchor",
      "cwd" => File.cwd!()
    }

    pane = %{
      "pane_id" => "w1:p9",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "terminal_id" => "run"
    }

    snapshot = %{
      "workspaces" => [%{"workspace_id" => "w1", "label" => "jarvis2"}],
      "panes" => [anchor],
      "agents" => []
    }

    mirror = start_supervised!({Mirror, %{stale: false, snapshot: snapshot}})
    prompt_guard = start_supervised!({Jarvis2.Herdr.PromptGuard, [name: nil]})

    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "ui-launch-#{System.unique_integer([:positive])}"
      )

    parent = self()

    {:ok, _, listener} =
      Jarvis2.Test.FakeHerdr.start_link(path, fn request ->
        method = request["method"]
        send(parent, {:request, method})

        result =
          case method do
            "pane.split" ->
              %{type: "pane_info", pane: pane}

            "pane.process_info" ->
              %{
                process_info: %{
                  pane_id: "w1:p9",
                  shell_pid: 7,
                  foreground_process_group_id: 7,
                  foreground_processes: [%{pid: 7}]
                }
              }

            "agent.start" ->
              agent =
                Map.merge(pane, %{"agent" => "pi", "agent_status" => "idle", "name" => "worker"})

              :ok =
                GenServer.call(
                  mirror,
                  {:put,
                   %{
                     stale: false,
                     snapshot: %{snapshot | "panes" => [anchor, pane], "agents" => [agent]}
                   }}
                )

              %{type: "agent_started", agent: agent}

            "agent.prompt" ->
              %{type: "agent_prompt", submitted: true}
          end

        {:reply, %{result: result}}
      end)

    socket = start_supervised!({Jarvis2.Herdr.Socket, [path: path, name: nil]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    for {key, value} <- [mirror: mirror, herdr_socket: socket, prompt_guard: prompt_guard],
        do: config(key, value)
  end

  defp config(key, value) do
    old = Application.fetch_env(:jarvis2, key)
    Application.put_env(:jarvis2, key, value)

    on_exit(fn ->
      case old do
        {:ok, previous} -> Application.put_env(:jarvis2, key, previous)
        :error -> Application.delete_env(:jarvis2, key)
      end
    end)
  end

  defp assert_eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(25) && assert_eventually(fun, attempts - 1)
    end
  end
end
