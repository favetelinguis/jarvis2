defmodule Jarvis2Web.SlidesController do
  use Jarvis2Web, :controller

  alias Jarvis2.Kanban
  alias Jarvis2.Kanban.{Card, Kind, Slides}

  def show(conn, %{"id" => id} = params) do
    with %Card{column: column, deliverable: html} = card
         when column in [:done, :archive] and is_binary(html) and html != "" <-
           Kanban.get_card(id),
         true <- Kind.deliverable_type(card.kind) == :html do
      body = html |> Slides.serve() |> IO.iodata_to_binary()

      conn =
        conn
        |> put_resp_header("content-security-policy", Slides.csp_header())
        |> put_resp_header("cache-control", "no-store")

      if params["download"] == "1" do
        send_download(conn, {:binary, body},
          filename: Slides.filename(card.title),
          content_type: "text/html"
        )
      else
        conn |> put_resp_content_type("text/html", "utf-8") |> send_resp(200, body)
      end
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
