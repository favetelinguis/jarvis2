defmodule Jarvis2Web.RunLive.New do
  use Jarvis2Web, :live_view

  alias Jarvis2.Herdr.Mirror
  alias Jarvis2.Runs
  alias Jarvis2.Runs.{Launcher, Run}

  @impl true
  def mount(_params, _session, socket) do
    view = mirror_view()
    attrs = Map.put(Runs.defaults(), :cwd, default_cwd(view))

    {:ok,
     socket
     |> assign(:availability, Launcher.availability(view))
     |> assign(:live?, Launcher.mode() == :live)
     |> assign(:kinds, Jarvis2.Herdr.Actions.agent_kinds())
     |> assign(:levels, Run.thinking_levels())
     |> assign_form(Runs.change_run(%Run{}, attrs))}
  end

  @impl true
  def handle_event("validate", %{"run" => params}, socket),
    do: {:noreply, assign_form(socket, Runs.change_run(%Run{}, params))}

  def handle_event("save", %{"run" => params}, socket) do
    case socket.assigns.availability do
      :ok ->
        case Runs.start_run(params) do
          {:ok, run} -> {:noreply, push_navigate(socket, to: "/runs/#{run.id}")}
          {:error, changeset} -> {:noreply, assign_form(socket, changeset)}
        end

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(%{changeset | action: :validate}, as: :run))

  defp mirror_view do
    Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))
  catch
    :exit, _ -> nil
  end

  defp default_cwd(%{snapshot: %{"panes" => panes} = snapshot}) do
    pane = Enum.find(panes, &(&1["pane_id"] == snapshot["focused_pane_id"]))
    (pane && (pane["foreground_cwd"] || pane["cwd"])) || File.cwd!()
  end

  defp default_cwd(_view), do: File.cwd!()

  @impl true
  def render(assigns) do
    ~H"""
    <h1>New run</h1>
    <p><.live_badge live={@live?} /></p>
    <p :if={match?({:error, _}, @availability)} id="unavailable" class="banner banner-warn">
      {elem(@availability, 1)} Starting is disabled until this is resolved.
    </p>
    <p :if={!@live? && @availability == :ok} class="muted">
      Dry-run: the run is recorded and the planned Herdr calls are shown, but nothing is started.
    </p>

    <.form for={@form} id="run-form" phx-change="validate" phx-submit="save" class="stack">
      <.field field={@form[:name]} label="Name" required />
      <.field field={@form[:cwd]} label="Working directory" required />
      <.field field={@form[:kind]} label="Agent" type="select" options={@kinds} />
      <.field field={@form[:model]} label="Model" required />
      <.field field={@form[:thinking]} label="Thinking" type="select" options={@levels} />
      <.field field={@form[:task]} label="Task" type="textarea" rows="6" required />
      <button type="submit" disabled={match?({:error, _}, @availability)}>Start</button>
    </.form>
    """
  end
end
