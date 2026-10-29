defmodule Jarvis2Web.SettingsLive do
  use Jarvis2Web, :live_view

  alias Jarvis2.Settings
  alias Jarvis2.Runs.Run

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
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

  # An unchecked list of checkboxes sends no key at all.
  defp normalize(params), do: Map.put_new(params, "scenarios", [])

  defp load(socket) do
    settings = Settings.get()

    assign_form(socket, Settings.change(settings))
  end

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(%{changeset | action: :validate}, as: :setting))

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Settings</h1>
    <p class="muted">
      <code>JARVIS2_SCENARIOS</code> restricts which actions may be enabled at all.
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

    <p class="muted">The UI sign-in token is stored in <code>{@token_path}</code>.</p>
    """
  end
end
