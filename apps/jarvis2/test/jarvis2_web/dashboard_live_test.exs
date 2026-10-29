defmodule Jarvis2Web.DashboardLiveTest do
  use Jarvis2Web.ConnCase, async: false

  defmodule StubMirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
  end

  setup %{conn: conn} do
    mirror = start_supervised!({StubMirror, view("working", stale: false)})
    previous = Application.fetch_env(:jarvis2, :mirror)
    Application.put_env(:jarvis2, :mirror, mirror)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:jarvis2, :mirror, value)
        :error -> Application.delete_env(:jarvis2, :mirror)
      end
    end)

    %{conn: conn, mirror: mirror}
  end

  test "redirects visitors without a session to the login page", %{conn: conn} do
    assert redirected_to(get(conn, "/")) == "/login"
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/")
  end

  test "a single-use code signs in once; wrong secrets are refused", %{conn: conn} do
    code = Jarvis2.LoginCodes.issue()
    assert redirected_to(get(conn, "/login?code=#{code}")) == "/"
    assert get(conn, "/login?code=#{code}").status == 401
    assert post(conn, "/login", %{"secret" => "nope"}).status == 401
    assert html_response(post(conn, "/login", %{"secret" => "nope"}), 401) =~ "not accepted"
  end

  test "the API token signs in through the form", %{conn: conn} do
    conn = post(conn, "/login", %{"secret" => Jarvis2.Token.get()})
    assert redirected_to(conn) == "/"
  end

  test "requests for other hosts are refused", %{conn: conn} do
    assert conn |> Map.put(:host, "evil.example") |> get("/healthz") |> response(403)
    assert conn |> Map.put(:host, "localhost") |> get("/healthz") |> response(200)
  end

  test "renders the session and updates agent status without a reload", ctx do
    {:ok, view, html} = ctx.conn |> sign_in() |> live("/")
    assert html =~ "Connected to Herdr."
    assert html =~ "Live: off"
    assert has_element?(view, "#pane-w1\\:p1")
    assert has_element?(view, "#agent-w1\\:p1 .badge-working")

    publish(ctx.mirror, view("blocked", stale: false))
    assert render(view) =~ "badge-blocked"
    refute has_element?(view, "#agent-w1\\:p1 .badge-working")

    publish(ctx.mirror, view("blocked", stale: true))
    assert render(view) =~ "stale"
  end

  test "ignores mirror updates from other sources", ctx do
    {:ok, view, _} = ctx.conn |> sign_in() |> live("/")
    stranger = spawn(fn -> Process.sleep(:infinity) end)

    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "mirror:updated",
      {:jarvis2, "mirror:updated", %{source: stranger, view: view("blocked", stale: false)}}
    )

    assert has_element?(view, "#agent-w1\\:p1 .badge-working")
  end

  test "streams newly journalled events", ctx do
    {:ok, view, _} = ctx.conn |> sign_in() |> live("/")
    {:ok, event} = Jarvis2.Journal.record(%{source: :mcp, type: "tool.live_check"})
    assert has_element?(view, "#events-#{event.id}", "tool.live_check")
  end

  defp publish(mirror, view) do
    :sys.replace_state(mirror, fn _ -> view end)

    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "mirror:updated",
      {:jarvis2, "mirror:updated", %{source: mirror, view: view}}
    )
  end

  defp view(status, stale: stale) do
    %{
      stale: stale,
      worktrees: %{},
      worktree_errors: %{},
      layout_diff: %{"status" => "changed", "changes" => [%{"kind" => "focus"}]},
      snapshot: %{
        "workspaces" => [%{"workspace_id" => "w1", "label" => "repo"}],
        "tabs" => [%{"tab_id" => "w1:t1", "workspace_id" => "w1", "label" => "main"}],
        "panes" => [
          %{"pane_id" => "w1:p1", "tab_id" => "w1:t1", "workspace_id" => "w1", "cwd" => "/repo"}
        ],
        "agents" => [
          %{"pane_id" => "w1:p1", "name" => "worker", "agent" => "pi", "agent_status" => status}
        ]
      }
    }
  end
end
