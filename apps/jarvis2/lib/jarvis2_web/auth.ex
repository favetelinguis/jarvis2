defmodule Jarvis2Web.Auth do
  @moduledoc "Session-based sign-in for the browser UI, as a plug and a LiveView `on_mount` hook."
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if get_session(conn, :authenticated) == true do
      conn
    else
      conn |> redirect(to: "/login") |> halt()
    end
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    if session["authenticated"] == true,
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
  end
end
