defmodule Jarvis2Web.HarnessLiveTest do
  use Jarvis2Web.ConnCase, async: false

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "jarvis2-pi-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    old_dir = Application.fetch_env(:jarvis2, :pi_agent_dir)
    old_port = Application.fetch_env(:jarvis2, :port)
    Application.put_env(:jarvis2, :pi_agent_dir, dir)
    Application.put_env(:jarvis2, :port, 9876)

    on_exit(fn ->
      for {key, old} <- [pi_agent_dir: old_dir, port: old_port] do
        case old do
          {:ok, value} -> Application.put_env(:jarvis2, key, value)
          :error -> Application.delete_env(:jarvis2, key)
        end
      end

      File.rm_rf!(dir)
    end)

    %{conn: sign_in(conn), path: Path.join(dir, "mcp.json")}
  end

  test "configures valid role models without changing role files", %{conn: conn, path: path} do
    roles = Path.join(Path.dirname(path), "roles")
    File.mkdir_p!(roles)
    old = Application.fetch_env!(:jarvis2, :roles_dir)
    Application.put_env(:jarvis2, :roles_dir, roles)
    on_exit(fn -> Application.put_env(:jarvis2, :roles_dir, old) end)

    planner = Path.join(roles, "planner.md")
    original = "---\nname: planner\nmodel: vendor/shipped\n---\nPlanner prompt"
    File.write!(planner, original)
    File.write!(Path.join(roles, "researcher.md"), "---\nname: researcher\n---\nResearch")
    File.write!(Path.join(roles, "invalid.md"), "---\nname: invalid\nmodel: bad\n---\nBad")
    {:ok, _} = Jarvis2.Settings.update(%{default_model: "vendor/default"})

    {:ok, view, _} = live(conn, "/harness")
    assert has_element?(view, "#role-model-planner input[value='vendor/shipped']")
    assert has_element?(view, "#role-model-researcher input[value='vendor/default']")
    assert has_element?(view, "#role-model-researcher", "Settings default")
    assert has_element?(view, "#role-model-planner", "Role file default")
    refute has_element?(view, "#role-model-invalid")

    assert view |> form("#role-model-planner", model: "vendor/local") |> render_submit() =~
             "saved"

    assert File.read!(planner) == original
    {:ok, view, _} = live(conn, "/harness")
    assert has_element?(view, "#role-model-planner input[value='vendor/local']")
    assert has_element?(view, "#role-model-planner", "Local override")

    assert view |> form("#role-model-planner", model: "vendor/$(id)") |> render_submit() =~
             "must look like provider/model"

    {:ok, view, _} = live(conn, "/harness")
    assert has_element?(view, "#role-model-planner input[value='vendor/local']")
    File.write!(planner, String.replace(original, "vendor/shipped", "vendor/updated"))
    assert view |> form("#role-model-planner", model: "") |> render_submit() =~ "saved"
    assert has_element?(view, "#role-model-planner input[value='vendor/updated']")
    assert File.read!(planner) == String.replace(original, "vendor/shipped", "vendor/updated")

    assert view
           |> form("#role-model-researcher", model: "vendor/local-research")
           |> render_submit() =~ "saved"

    assert view |> form("#role-model-researcher", model: "") |> render_submit() =~ "saved"
    assert has_element?(view, "#role-model-researcher input[value='vendor/default']")

    File.write!(
      Path.join(roles, "new-role.md"),
      "---\nname: new-role\nmodel: vendor/new\n---\nNew"
    )

    {:ok, view, _} = live(conn, "/harness")
    assert has_element?(view, "#role-model-new-role input[value='vendor/new']")
  end

  test "requires authentication" do
    conn = Phoenix.ConnTest.build_conn() |> Map.put(:host, "127.0.0.1")
    assert redirected_to(get(conn, "/harness")) == "/login"
  end

  test "installs Pi card creation without disturbing existing servers", %{conn: conn, path: path} do
    initial = %{
      "autoEnableCodemode" => false,
      "mcpServers" => %{"other" => %{"command" => "example", "env" => %{"KEY" => "secret"}}}
    }

    File.write!(path, Jason.encode!(initial))
    File.chmod!(path, 0o640)
    {:ok, view, html} = live(conn, "/harness")
    assert html =~ "Harness"
    assert has_element?(view, "a[href='/harness']", "Harness")
    assert html =~ path
    assert html =~ "Not installed"
    refute html =~ "secret"
    assert File.read!(path) == Jason.encode!(initial)

    changed =
      put_in(initial, ["mcpServers", "added_after_mount"], %{"url" => "https://example.com"})

    File.write!(path, Jason.encode!(changed))

    assert view |> element("#install-pi") |> render_click() =~ "installed"
    result = path |> File.read!() |> Jason.decode!()
    assert result["autoEnableCodemode"] == false
    assert result["mcpServers"]["other"] == initial["mcpServers"]["other"]
    assert result["mcpServers"]["added_after_mount"] == changed["mcpServers"]["added_after_mount"]

    assert result["mcpServers"]["jarvis2_board"] == %{
             "url" => "http://127.0.0.1:9876/mcp/board",
             "description" => "Create Jarvis2 kanban cards for the current working directory.",
             "exposure" => "direct"
           }

    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o640
    assert render(view) =~ "Installed"
    assert render(view) =~ "/reload"
    before = File.read!(path)
    render_hook(view, "install_pi", %{})
    assert File.read!(path) == before
  end

  test "creates a missing MCP config and updates a stale installation", %{conn: conn, path: path} do
    dir = Path.join(Path.dirname(path), "new/agent")
    Application.put_env(:jarvis2, :pi_agent_dir, dir)
    path = Path.join(dir, "mcp.json")
    {:ok, view, _} = live(conn, "/harness")
    refute File.exists?(path)
    view |> element("#install-pi") |> render_click()
    assert File.regular?(path)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    Application.put_env(:jarvis2, :port, 1234)
    {:ok, view, html} = live(conn, "/harness")
    assert html =~ "Update available"
    view |> element("#install-pi") |> render_click()

    assert path
           |> File.read!()
           |> Jason.decode!()
           |> get_in(["mcpServers", "jarvis2_board", "url"]) ==
             "http://127.0.0.1:1234/mcp/board"
  end

  test "updates the previous full-server Pi configuration", %{conn: conn, path: path} do
    previous = %{
      "mcpServers" => %{
        "jarvis2_board" => %{
          "url" => "http://127.0.0.1:9876/mcp",
          "exposure" => "hidden",
          "toolExposure" => %{"create_card" => "direct"}
        },
        "other" => %{"url" => "https://example.com"}
      }
    }

    File.write!(path, Jason.encode!(previous))
    {:ok, view, html} = live(conn, "/harness")
    assert html =~ "Update available"
    view |> element("#install-pi") |> render_click()
    result = path |> File.read!() |> Jason.decode!()
    assert result["mcpServers"]["jarvis2_board"]["url"] == "http://127.0.0.1:9876/mcp/board"
    assert result["mcpServers"]["jarvis2_board"]["exposure"] == "direct"
    assert result["mcpServers"]["other"] == previous["mcpServers"]["other"]
  end

  test "reports invalid configurations without overwriting them", %{conn: conn, path: path} do
    for text <- ["{bad", "[]", ~s({"mcpServers": []}), ~s({"mcpServers":{"jarvis2-board":{}}})] do
      File.write!(path, text)
      {:ok, view, _} = live(conn, "/harness")
      assert render(view) =~ "Cannot install"
      render_hook(view, "install_pi", %{})
      assert render(view) =~ "Cannot install"
      assert File.read!(path) == text
    end
  end

  test "reports a non-file configuration without modifying it", %{conn: conn, path: path} do
    File.mkdir!(path)
    {:ok, view, html} = live(conn, "/harness")
    assert html =~ "Cannot read"
    render_hook(view, "install_pi", %{})
    assert File.dir?(path)
  end

  test "does not replace symlinked configuration", %{conn: conn, path: path} do
    target = path <> ".target"
    File.write!(target, "{}")
    File.ln_s!(target, path)
    {:ok, view, html} = live(conn, "/harness")
    assert html =~ "symlink"
    render_hook(view, "install_pi", %{})
    assert File.read!(target) == "{}"
    assert {:ok, %{type: :symlink}} = File.lstat(path)
  end
end
