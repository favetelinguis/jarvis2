defmodule Jarvis2Web.HarnessLive do
  use Jarvis2Web, :live_view

  alias Jarvis2.{Harness, Roles, Settings}

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

  def handle_event("save_role_model", %{"role" => role, "model" => model}, socket) do
    case Settings.save_role_model(role, model) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Role model saved.")}

      {:error, :invalid_model} ->
        {:noreply,
         socket
         |> load()
         |> assign(:model_error, {role, "must look like provider/model"})
         |> assign(:submitted_model, model)}

      {:error, _} ->
        {:noreply, socket |> load() |> put_flash(:error, "Cannot save role model.")}
    end
  end

  def handle_event("save_role_model", _params, socket) do
    {:noreply, socket |> load() |> put_flash(:error, "Cannot save role model.")}
  end

  defp load(socket) do
    settings = Settings.get()
    overrides = Settings.role_models()

    roles =
      for {:ok, role} <- Roles.list() do
        source =
          cond do
            Map.has_key?(overrides, role.name) -> "Local override"
            role.model -> "Role file default"
            true -> "Settings default"
          end

        %{
          name: role.name,
          model: Settings.effective_role_model(role, settings, overrides),
          source: source
        }
      end

    socket
    |> assign(:path, Harness.pi_config_path())
    |> assign(:pi_status, Harness.pi_status())
    |> assign(:roles, roles)
    |> assign(:model_error, nil)
    |> assign(:submitted_model, nil)
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
    <h2>Role models</h2>
    <p>Save a local model for new runs, or clear the field to use the current default.</p>
    <%= for role <- @roles do %>
      <form id={"role-model-#{role.name}"} phx-submit="save_role_model">
        <input type="hidden" name="role" value={role.name} />
        <label for={"model-#{role.name}"}>{role.name} model</label>
        <input
          id={"model-#{role.name}"}
          name="model"
          value={
            if @model_error && elem(@model_error, 0) == role.name,
              do: @submitted_model,
              else: role.model
          }
          aria-invalid={@model_error && elem(@model_error, 0) == role.name}
        />
        <span class="muted">{role.source}</span>
        <button type="submit">Save</button>
        <%= if @model_error && elem(@model_error, 0) == role.name do %>
          <p class="flash-error">Model {elem(@model_error, 1)}</p>
        <% end %>
      </form>
    <% end %>
    """
  end
end
