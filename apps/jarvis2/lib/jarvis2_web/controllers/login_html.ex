defmodule Jarvis2Web.LoginHTML do
  use Jarvis2Web, :html

  attr(:error, :string, default: nil)

  def new(assigns) do
    ~H"""
    <main>
      <h1>Jarvis2</h1>
      <p :if={@error} class="flash flash-error">{@error}</p>
      <p class="muted">
        Open the sign-in link printed when the server started, or paste the API token from <code>$JARVIS2_STATE_DIR/token</code>.
      </p>
      <.form for={%{}} action="/login" class="stack">
        <input type="password" name="secret" placeholder="Sign-in code or token" autocomplete="off" />
        <button type="submit">Sign in</button>
      </.form>
    </main>
    """
  end
end
