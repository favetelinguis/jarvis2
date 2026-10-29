defmodule Jarvis2Web.SlidesControllerTest do
  use Jarvis2Web.ConnCase, async: false
  import Plug.Conn, only: [get_resp_header: 2]
  alias Jarvis2.{Kanban, Repo}

  @html "<!doctype html><html><head><title>Deck</title></head><body>Slides</body></html>"

  test "serves only completed decks to authenticated users", %{conn: conn} do
    {:ok, card} = Kanban.create_card(%{title: "Q3 Deck", kind: :slides, cwd: File.cwd!()})
    card = card |> Ecto.Changeset.change(column: :done, deliverable: @html) |> Repo.update!()
    path = "/kanban/cards/#{card.id}/slides"
    assert redirected_to(get(conn, path)) == "/login"
    conn = sign_in(conn)
    response = get(conn, path)
    assert html_response(response, 200) =~ ~s(http-equiv="Content-Security-Policy")
    [csp] = get_resp_header(response, "content-security-policy")
    assert csp =~ "sandbox allow-scripts"
    refute csp =~ "allow-same-origin"
    assert get_resp_header(response, "cache-control") == ["no-store"]
    download = get(conn, path <> "?download=1")
    body = response(download, 200)
    assert body =~ "Slides"
    assert body =~ ~s(http-equiv="Content-Security-Policy")
    refute body =~ "/login"
    refute body =~ "Sign in"

    assert get_resp_header(download, "content-disposition") == [
             ~s(attachment; filename="q3-deck.html")
           ]

    assert response(get(conn, "/kanban/cards/#{Ecto.UUID.generate()}/slides"), 404)
    {:ok, other} = Kanban.create_card(%{title: "Other", cwd: File.cwd!()})
    other |> Ecto.Changeset.change(column: :done, deliverable: @html) |> Repo.update!()
    assert response(get(conn, "/kanban/cards/#{other.id}/slides"), 404)
    card |> Ecto.Changeset.change(column: :agent) |> Repo.update!()
    assert response(get(conn, path), 404)
    card |> Ecto.Changeset.change(column: :archive, deliverable: nil) |> Repo.update!()
    assert response(get(conn, path), 404)
  end
end
