defmodule Jarvis2Web.RunLive.Show do
  use Jarvis2Web, :live_view

  alias Jarvis2.{Journal, Questions, Runs}
  alias Jarvis2.Runs.Run

  @event_limit 200

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Runs.get_run(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Run not found.") |> push_navigate(to: "/runs")}

      run ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Jarvis2.PubSub, "run:" <> run.id)
        end

        events = Journal.recent(run_id: run.id, limit: @event_limit) |> Enum.reverse()

        {:ok,
         socket
         |> assign(:run, run)
         |> assign(:questions, Questions.list_for_run(run.id))
         |> assign(:prompt_form, to_form(%{"text" => ""}, as: :prompt))
         |> stream(:events, events)}
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

  def handle_event("answer", params, socket),
    do: {:noreply, Jarvis2Web.QuestionActions.answer(socket, params)}

  def handle_event("stop", _params, socket) do
    case Runs.stop_run(socket.assigns.run) do
      {:ok, run} -> {:noreply, socket |> assign(:run, run) |> put_flash(:info, "Run stopped.")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("focus", _params, socket) do
    case Runs.focus_run(socket.assigns.run) do
      {:ok, _} -> {:noreply, socket}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:run, run}, socket),
    do: {:noreply, assign(socket, :run, run)}

  def handle_info({:event, event}, socket),
    do: {:noreply, stream_insert(socket, :events, event, at: 0, limit: @event_limit)}

  def handle_info({:question, _question}, socket),
    do: {:noreply, assign(socket, :questions, Questions.list_for_run(socket.assigns.run.id))}

  @impl true
  def render(assigns) do
    ~H"""
    <p><.link navigate="/runs">← Runs</.link></p>
    <h1>{@run.name} <.status_badge status={@run.status} /></h1>
    <p>
      <span class="muted">
        {@run.kind}<span :if={@run.kind != "mix"}> · {@run.model} ({@run.thinking})</span>
        · <code>{@run.cwd}</code>
      </span>
      <span :if={@run.pane_id}> · pane <code>{@run.pane_id}</code></span>
    </p>
    <p :if={error = @run.result && @run.result["error"]} class="flash flash-error" id="run-error">
      {error}
    </p>

    <p :if={Run.active?(@run)} class="actions">
      <button :if={@run.pane_id} phx-click="focus" id="focus">Open in Herdr</button>
      <button
        :if={@run.kind != "mix"}
        phx-click="stop"
        id="stop"
        data-confirm="Stop this run and close its pane?"
      >
        Stop
      </button>
    </p>

    <section :if={summary = @run.result && @run.result["summary"]} id="result">
      <h2>Result</h2>
      <p>{summary}</p>
      <ul :if={@run.result["artifacts"] not in [nil, []]}>
        <li :for={artifact <- @run.result["artifacts"]}><code>{artifact}</code></li>
      </ul>
    </section>

    <section :if={@run.result && @run.result["output"]} id="mix-output">
      <h2>Mix output</h2>
      <p class="muted">
        exit status {@run.result["exit_status"]}{if @run.result["timed_out"], do: " (timed out)"}{if @run.result[
                                                                                                       "truncated"
                                                                                                     ],
                                                                                                     do:
                                                                                                       " · output truncated"}
      </p>
      <pre class="tail">{@run.result["output"]}</pre>
    </section>

    <section :if={@questions != []} id="questions">
      <h2>Waiting for you</h2>
      <.question_card :for={question <- @questions} question={question} />
    </section>

    <section :if={Run.active?(@run) and @run.pane_id} id="prompt">
      <h2>Prompt</h2>
      <.form for={@prompt_form} phx-submit="prompt" class="stack">
        <textarea name="prompt[text]" rows="3" placeholder="Message to the agent"></textarea>
        <button type="submit">Send</button>
      </.form>
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
