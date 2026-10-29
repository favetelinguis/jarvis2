defmodule Jarvis2Web.SettingsLive do
  use Jarvis2Web, :live_view

  alias Jarvis2.{Runs, Settings, Tokens}
  alias Jarvis2.Runs.Run

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:live?, Application.get_env(:jarvis2, :live, false))
     |> assign(:kinds, Jarvis2.Herdr.Actions.agent_kinds())
     |> assign(:levels, Run.thinking_levels())
     |> assign(:token_path, Path.join(Application.get_env(:jarvis2, :state_dir, ""), "token"))
     |> load()}
  end

  @impl true
  def handle_event("validate", %{"setting" => params}, socket),
    do: {:noreply, assign_form(socket, Settings.change(Settings.get(), normalize(params)))}

  def handle_event("save", %{"setting" => params}, socket) do
    case Settings.update(normalize(params)) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Settings saved.") |> load()}
      {:error, changeset} -> {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    Tokens.revoke(id)
    {:noreply, load(socket)}
  end

  # An unchecked list of checkboxes sends no key at all.
  defp normalize(params), do: Map.put_new(params, "scenarios", [])

  defp load(socket) do
    settings = Settings.get()

    socket
    |> assign_form(Settings.change(settings))
    |> assign(:tokens, Enum.map(Tokens.list_active(), &{&1, Runs.get_run(&1.run_id)}))
  end

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(%{changeset | action: :validate}, as: :setting))

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Settings</h1>
    <p><.live_badge live={@live?} /></p>
    <p :if={!@live?} class="banner banner-warn">
      This server runs in dry-run mode. Enabled actions below are only planned and logged until it is
      started with <code>JARVIS2_LIVE=1</code>.
    </p>
    <p class="muted">
      Live mode is set by the environment and can never be switched on from here. Setting
      <code>JARVIS2_SCENARIOS</code>
      restricts which actions may be enabled at all.
    </p>

    <.form for={@form} id="settings-form" phx-change="validate" phx-submit="save" class="stack">
      <fieldset>
        <legend>Actions</legend>
        <label :for={{name, description} <- Settings.scenarios()} class="check">
          <input
            type="checkbox"
            name="setting[scenarios][]"
            value={name}
            checked={name in (@form[:scenarios].value || [])}
            disabled={!Settings.allowed?(String.to_atom(name))}
          />
          <span>
            <strong>{name}</strong>
            <span class="muted">{description}</span>
            <span :if={!Settings.allowed?(String.to_atom(name))} class="muted">
              (locked by the environment)
            </span>
          </span>
        </label>
        <.errors field={@form[:scenarios]} />
      </fieldset>

      <fieldset>
        <legend>New run defaults</legend>
        <.field field={@form[:default_kind]} label="Agent" type="select" options={@kinds} />
        <.field field={@form[:default_model]} label="Model" />
        <.field field={@form[:default_thinking]} label="Thinking" type="select" options={@levels} />
      </fieldset>
      <button type="submit">Save</button>
    </.form>

    <section id="tokens">
      <h2>Access tokens</h2>
      <p class="muted">
        The API token for agents that are not runs is in <code>{@token_path}</code>. Run tokens are
        created when a run starts and revoked when it ends; you can revoke one early here.
      </p>
      <table>
        <thead>
          <tr>
            <th>Run</th><th>Expires</th><th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{token, run} <- @tokens} id={"token-#{token.id}"}>
            <td>
              <.link :if={run} navigate={"/runs/#{run.id}"}>{run.name}</.link>
              <span :if={!run} class="muted">unknown run</span>
            </td>
            <td>{Calendar.strftime(token.expires_at, "%Y-%m-%d %H:%M")}</td>
            <td><button phx-click="revoke" phx-value-id={token.id}>Revoke</button></td>
          </tr>
        </tbody>
      </table>
      <p :if={@tokens == []} class="muted">No active run tokens.</p>
    </section>
    """
  end
end
