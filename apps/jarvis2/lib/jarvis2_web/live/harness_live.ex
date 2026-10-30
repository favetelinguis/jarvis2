defmodule Jarvis2Web.HarnessLive do
  use Jarvis2Web, :live_view

  alias Jarvis2.Harness

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  @impl true
  def handle_event("install_pi", _params, socket) do
    case Harness.install_pi() do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, "Pi integration installed. Reload Pi to use it.") |> load()}

      {:error, message} ->
        {:noreply, socket |> put_flash(:error, "Cannot install: " <> message) |> load()}
    end
  end

  defp load(socket) do
    socket
    |> assign(:path, Harness.pi_config_path())
    |> assign(:pi_status, Harness.pi_status())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Harness</h1>
    <h2>Pi</h2>
    <fieldset>
      <legend>Install card creation</legend>
      <p>
        Let manually started Pi sessions create Scratch cards for their working directory.
        Installing does not start an agent.
      </p>
      <p>Global MCP configuration on this machine: <code>{@path}</code></p>
      <p>
        The installer adds or replaces <code>jarvis2_board</code> and preserves other servers and
        settings. It exposes only <code>create_card</code> in Pi.
      </p>
      <%= case @pi_status do %>
        <% {:ok, :installed} -> %>
          <p>Installed</p>
        <% {:ok, :missing} -> %>
          <p>Not installed</p>
        <% {:ok, :update} -> %>
          <p>Update available</p>
        <% {:error, message} -> %>
          <p class="flash-error">Cannot install: {message}</p>
      <% end %>
      <button
        id="install-pi"
        type="button"
        phx-click="install_pi"
        disabled={match?({:ok, :installed}, @pi_status) or match?({:error, _}, @pi_status)}
      >
        Install Pi integration
      </button>
      <p class="muted">
        Start Pi or run <code>/reload</code> in an existing session after installing. Jarvis2 must
        be running. Pi may override global servers in trusted projects.
      </p>
    </fieldset>
    """
  end
end
