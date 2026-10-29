defmodule Jarvis2Web.LoginController do
  use Jarvis2Web, :controller

  plug :put_view, html: Jarvis2Web.LoginHTML

  # The URL printed at boot carries a single-use code; pasting the API token is the fallback.
  def new(conn, %{"code" => code}) when is_binary(code), do: sign_in(conn, code)
  def new(conn, _params), do: render(conn, :new, error: nil)

  def create(conn, %{"secret" => secret}) when is_binary(secret), do: sign_in(conn, secret)
  def create(conn, _params), do: render(conn, :new, error: nil)

  def delete(conn, _params) do
    conn |> configure_session(drop: true) |> redirect(to: "/login")
  end

  defp sign_in(conn, secret) do
    secret = String.trim(secret)

    if Jarvis2.LoginCodes.redeem(secret) == :ok or
         Plug.Crypto.secure_compare(secret, Jarvis2.Token.get()) do
      conn
      |> configure_session(renew: true)
      |> put_session(:authenticated, true)
      |> redirect(to: "/")
    else
      conn |> put_status(401) |> render(:new, error: "That code or token was not accepted.")
    end
  end
end
