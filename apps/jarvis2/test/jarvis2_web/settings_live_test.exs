defmodule Jarvis2Web.SettingsLiveTest do
  use Jarvis2Web.ConnCase, async: false

  alias Jarvis2.{Runs, Settings, Tokens}

  setup %{conn: conn} do
    for key <- [:live_scenarios, :allowed_scenarios, :live] do
      old = Application.fetch_env(:jarvis2, key)

      on_exit(fn ->
        case old do
          {:ok, v} -> Application.put_env(:jarvis2, key, v)
          :error -> Application.delete_env(:jarvis2, key)
        end
      end)
    end

    Application.delete_env(:jarvis2, :allowed_scenarios)
    Application.put_env(:jarvis2, :live, false)
    %{conn: sign_in(conn)}
  end

  test "requires a session" do
    conn = Phoenix.ConnTest.build_conn() |> Map.put(:host, "127.0.0.1")
    assert redirected_to(get(conn, "/settings")) == "/login"
  end

  test "explains dry-run and saves toggles and defaults", %{conn: conn} do
    {:ok, view, html} = live(conn, "/settings")
    assert html =~ "dry-run mode"
    refute has_element?(view, ~s(input[value="agent_spawn"][checked]))

    view
    |> form("#settings-form",
      setting: %{scenarios: ["agent_spawn", "agent_prompt"], default_thinking: "high"}
    )
    |> render_submit()

    assert render(view) =~ "Settings saved."
    assert has_element?(view, ~s(input[value="agent_spawn"][checked]))

    assert has_element?(
             view,
             ~s(select[name="setting[default_thinking]"] option[value="high"][selected])
           )

    assert Settings.get().scenarios == ["agent_spawn", "agent_prompt"]

    assert Enum.sort(Application.get_env(:jarvis2, :live_scenarios)) == [
             :agent_prompt,
             :agent_spawn
           ]
  end

  test "unchecking everything clears the scenarios", %{conn: conn} do
    {:ok, _} = Settings.update(%{scenarios: ["attention"]})
    {:ok, view, _} = live(conn, "/settings")
    assert has_element?(view, ~s(input[value="attention"][checked]))

    view |> form("#settings-form", setting: %{scenarios: []}) |> render_submit()
    assert Settings.get().scenarios == []
    assert Application.get_env(:jarvis2, :live_scenarios) == []
  end

  test "invalid defaults are reported and not saved", %{conn: conn} do
    {:ok, view, _} = live(conn, "/settings")

    html =
      view
      |> form("#settings-form", setting: %{default_model: "bad model; x"})
      |> render_change()

    assert html =~ "must look like provider/model"
    view |> form("#settings-form", setting: %{default_model: "bad model; x"}) |> render_submit()
    assert Settings.get().default_model == "openrouter/openai/gpt-6-luna"
  end

  test "scenarios locked by the environment cannot be toggled", %{conn: conn} do
    Application.put_env(:jarvis2, :allowed_scenarios, [:attention])
    {:ok, view, _} = live(conn, "/settings")
    assert has_element?(view, ~s(input[value="agent_spawn"][disabled]))
    refute has_element?(view, ~s(input[value="attention"][disabled]))
  end

  test "lists active run tokens and revokes them", %{conn: conn} do
    {:ok, run} = Runs.create_run(%{name: "tokened", task: "t", cwd: File.cwd!()})
    {:ok, plain} = Tokens.mint_for_run(run.id)
    [token] = Tokens.list_active()

    {:ok, view, html} = live(conn, "/settings")
    assert html =~ "tokened"
    refute html =~ plain

    view |> element("#token-#{token.id} button", "Revoke") |> render_click()
    refute has_element?(view, "#token-#{token.id}")
    assert Tokens.resolve(plain) == :error
    assert render(view) =~ "No active run tokens."
  end
end
