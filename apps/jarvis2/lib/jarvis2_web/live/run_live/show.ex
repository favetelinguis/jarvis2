defmodule Jarvis2Web.RunLive.Show do
  use Jarvis2Web, :live_view

  alias Jarvis2.{Journal, Runs}
  alias Jarvis2.Runs.{Run, Tail}

  @event_limit 200

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Runs.get_run(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Run not found.") |> push_navigate(to: "/runs")}

      run ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Jarvis2.PubSub, "run:" <> run.id)
          Phoenix.PubSub.subscribe(Jarvis2.PubSub, Tail.topic(run.id))
        end

        events = Journal.recent(run_id: run.id, limit: @event_limit) |> Enum.reverse()

        {:ok,
         socket
         |> assign(:run, run)
         |> assign(:live?, Runs.Launcher.mode() == :live)
         |> assign(:tail, nil)
         |> assign(:prompt_form, to_form(%{"text" => ""}, as: :prompt))
         |> stream(:events, events)
         |> watch_tail()}
    end
  end

  @impl true
  def handle_event("prompt", %{"prompt" => %{"text" => text}}, socket) do
    case Runs.prompt_run(socket.assigns.run, text) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Prompt sent.")
         |> assign(:prompt_form, to_form(%{"text" => ""}, as: :prompt))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("stop", _params, socket) do
    case Runs.stop_run(socket.assigns.run) do
      {:ok, run} -> {:noreply, socket |> assign(:run, run) |> put_flash(:info, "Run stopped.")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("focus", _params, socket) do
    case Runs.focus_run(socket.assigns.run) do
      {:ok, :dry_run} -> {:noreply, put_flash(socket, :info, "Dry-run: would focus the pane.")}
      {:ok, _} -> {:noreply, socket}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:run, run}, socket),
    do: {:noreply, socket |> assign(:run, run) |> watch_tail()}

  def handle_info({:event, event}, socket),
    do: {:noreply, stream_insert(socket, :events, event, at: 0, limit: @event_limit)}

  def handle_info({:tail, text}, socket), do: {:noreply, assign(socket, :tail, text)}

  defp watch_tail(socket) do
    run = socket.assigns.run

    if connected?(socket) and Run.active?(run) and run.pane_id,
      do: assign(socket, :tail, Tail.watch(run.id) || socket.assigns.tail),
      else: socket
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p><.link navigate="/runs">← Runs</.link></p>
    <h1>{@run.name} <.status_badge status={@run.status} /></h1>
    <p>
      <.live_badge live={@live?} />
      <span class="muted">
        {@run.kind} · {@run.model} ({@run.thinking}) · <code>{@run.cwd}</code>
      </span>
      <span :if={@run.pane_id}> · pane <code>{@run.pane_id}</code></span>
    </p>
    <p :if={error = @run.result && @run.result["error"]} class="flash flash-error" id="run-error">
      {error}
    </p>

    <p :if={Run.active?(@run) or @run.status == :dry_run} class="actions">
      <button :if={@run.pane_id} phx-click="focus" id="focus">Open in Herdr</button>
      <button phx-click="stop" id="stop" data-confirm="Stop this run and close its pane?">
        Stop
      </button>
    </p>

    <section :if={Run.active?(@run) and @run.pane_id} id="prompt">
      <h2>Prompt</h2>
      <.form for={@prompt_form} phx-submit="prompt" class="stack">
        <textarea name="prompt[text]" rows="3" placeholder="Message to the agent"></textarea>
        <button type="submit">Send</button>
      </.form>
    </section>

    <section :if={@tail} id="tail-section">
      <h2>Terminal</h2>
      <pre id="tail" class="tail">{@tail}</pre>
    </section>

    <section id="timeline-section">
      <h2>Timeline</h2>
      <table>
        <thead>
          <tr>
            <th>Time</th><th>Type</th><th>Outcome</th><th>Details</th>
          </tr>
        </thead>
        <tbody id="timeline" phx-update="stream">
          <tr :for={{id, event} <- @streams.events} id={id}>
            <td>{Calendar.strftime(event.inserted_at, "%H:%M:%S")}</td>
            <td>{event.type}</td>
            <td>{event.outcome}</td>
            <td><code class="payload">{Jason.encode!(event.payload)}</code></td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end
end
