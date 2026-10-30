defmodule Jarvis2Web.RolesLive do
  use Jarvis2Web, :live_view

  alias Jarvis2.{Roles, StepRoles}
  alias Jarvis2.Kanban.Kind

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  @impl true
  def handle_event("reload", _, socket), do: {:noreply, load(socket)}

  def handle_event("assign", %{"kind" => kind, "stage" => stage, "role" => role}, socket) do
    case StepRoles.assign(kind, stage, role) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Role assignment saved.") |> load()}

      {:error, message} when is_binary(message) ->
        {:noreply, socket |> put_flash(:error, message) |> load()}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Could not save assignment.") |> load()}
    end
  end

  defp load(socket) do
    roles = Roles.list()
    valid = for {:ok, role} <- roles, do: role

    steps =
      for {kind, stage} <- StepRoles.steps() do
        name = StepRoles.role_name(kind, stage)

        %{
          kind: kind,
          label: Kind.get(kind).label,
          stage: stage,
          role: name,
          default: Kind.stage(kind, stage).role,
          warning: Enum.all?(valid, &(&1.name != name))
        }
      end

    socket
    |> assign(:roles, roles)
    |> assign(:valid, valid)
    |> assign(:steps, steps)
    |> assign(:dir, Roles.dir())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Roles</h1>
    <p>Roles are edited as Markdown files in <code>{@dir}</code>.</p>
    <button type="button" phx-click="reload">Reload</button>
    <h2>Steps</h2>
    <table>
      <thead>
        <tr>
          <th>Kind</th><th>Stage</th><th>Role</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={step <- @steps}>
          <td>{step.label}</td><td>{step.stage}</td>
          <td>
            <form phx-change="assign" id={"role-#{step.kind}-#{step.stage}"}>
              <input type="hidden" name="kind" value={step.kind} />
              <input type="hidden" name="stage" value={step.stage} />
              <select name="role" aria-label={"#{step.label} #{step.stage} role"}>
                <option :if={step.warning} value={step.role} selected>
                  {step.role} (missing or invalid)
                </option>
                <option :for={role <- @valid} value={role.name} selected={role.name == step.role}>
                  {role.name}{if role.name == step.default, do: " (default)"}
                </option>
              </select>
            </form>
            <span :if={step.warning} class="flash-error">Mapped role is missing or invalid.</span>
          </td>
        </tr>
      </tbody>
    </table>
    <h2>Role files</h2>
    <ul>
      <li :for={entry <- @roles}>
        <%= case entry do %>
          <% {:ok, role} -> %>
            <strong>{role.name}</strong>
            — {role.description} (model: {role.model || "Settings default"}; effort: {role.effort ||
              "Settings default"})
          <% {:error, error} -> %>
            <strong>{error.file}</strong> — {error.reason}
        <% end %>
      </li>
    </ul>
    """
  end
end
