defmodule Jarvis2Web.KanbanLive.Index do
  # Interview drafts and feedback must not be included in LiveView's parameter logs.
  use Phoenix.LiveView, layout: {Jarvis2Web.Layouts, :app}, log: false
  import Jarvis2Web.Components
  alias Phoenix.LiveView.JS
  alias Jarvis2.{Kanban, Runs}
  alias Jarvis2.Kanban.{Card, Kind}

  @columns [
    {:scratch, "Scratch"},
    {:agent, "Agent"},
    {:awaiting_user, "Awaiting user"},
    {:done, "Done"},
    {:archive, "Archive"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Jarvis2.PubSub, Kanban.topic())
      Phoenix.PubSub.subscribe(Jarvis2.PubSub, Runs.topic())
    end

    cwd = Application.get_env(:jarvis2, :mix_project_dir, File.cwd!())

    {:ok,
     socket
     |> assign(columns: @columns, card: nil, feedback: "")
     |> assign_form(Kanban.change_card(%Card{}, %{cwd: cwd}))
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["id"] do
      nil ->
        {:noreply, assign(socket, card: nil, feedback: "")}

      id ->
        case Kanban.get_card(id) do
          nil ->
            {:noreply,
             socket |> put_flash(:error, "Card not found.") |> push_patch(to: "/kanban")}

          card ->
            {:noreply, assign(socket, card: card, feedback: "")}
        end
    end
  end

  @impl true
  def handle_event("validate", %{"card" => attrs}, socket) do
    changeset = Kanban.change_card(%Card{}, attrs)
    {:noreply, assign_form(socket, %{changeset | action: :validate})}
  end

  def handle_event("create", %{"card" => attrs}, socket) do
    case Kanban.create_card(attrs) do
      {:ok, _} ->
        cwd = Application.get_env(:jarvis2, :mix_project_dir, File.cwd!())
        {:noreply, socket |> assign_form(Kanban.change_card(%Card{}, %{cwd: cwd})) |> load()}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("move_card", %{"id" => id, "to" => to}, socket) do
    case Kanban.get_card(id) do
      %Card{column: column} when column in [:done, :archive] and to == "agent" ->
        {:reply, %{ok: true}, push_patch(socket, to: "/kanban/cards/#{id}/reopen")}

      %Card{} = card ->
        case Kanban.move(card, to) do
          {:ok, _} ->
            {:reply, %{ok: true}, load(socket)}

          {:error, message} ->
            {:reply, %{ok: false}, socket |> put_flash(:error, message) |> load()}
        end

      nil ->
        {:reply, %{ok: false}, put_flash(socket, :error, "Card not found.")}
    end
  end

  def handle_event("feedback", %{"feedback" => text}, socket),
    do: {:noreply, assign(socket, feedback: text)}

  def handle_event("reopen", %{"feedback" => text}, socket) do
    case Kanban.reopen(socket.assigns.card, text) do
      {:ok, _} ->
        {:noreply, socket |> load() |> push_patch(to: "/kanban")}

      {:error, message} ->
        {:noreply, socket |> assign(feedback: text) |> put_flash(:error, message)}
    end
  end

  def handle_event("retry", %{"id" => id}, socket) do
    case Kanban.get_card(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Card not found.")}

      card ->
        case Kanban.retry_delivery(card) do
          {:ok, _} -> {:noreply, put_flash(socket, :info, "Retrying delivery.")}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  @impl true
  def handle_info({:card, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:run, _}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    socket = load(socket)

    case socket.assigns.card do
      nil -> socket
      card -> assign(socket, :card, Kanban.get_card(card.id))
    end
  end

  defp load(socket), do: assign(socket, cards: Kanban.list_cards())

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset, as: :card))

  defp kind_hint(form) do
    kind = Ecto.Changeset.get_field(form.source, :kind) || :plan
    Kind.get(kind).hint
  end

  defp open_round(card), do: Enum.find(card.rounds, &(&1.status == :open))

  defp pending?(card),
    do:
      Enum.any?(card.rounds, &(&1.status == :answered and is_nil(&1.delivered_at))) or
        Enum.any?(card.feedback, &is_nil(&1.delivered_at))

  defp status(%{status: :done}), do: :idle
  defp status(run), do: run.status
  defp detail_path(%Card{column: :awaiting_user, id: id}), do: "/kanban/cards/#{id}/answer"
  defp detail_path(%Card{id: id}), do: "/kanban/cards/#{id}"

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Kanban</h1>
    <div id="board" class="kanban-board" phx-hook="Board">
      <section
        :for={{column, label} <- @columns}
        class={["kanban-column", column == :awaiting_user && "waiting"]}
        data-column={column}
      >
        <h2>{label}</h2>
        <.form
          :if={column == :scratch}
          for={@form}
          id="card-form"
          phx-change="validate"
          phx-submit="create"
          class="stack"
        >
          <.field field={@form[:title]} label="Add card" required />
          <label>
            Type
            <select id={@form[:kind].id} name={@form[:kind].name}>
              <option
                :for={kind <- Kind.all()}
                value={kind}
                selected={to_string(@form[:kind].value) == to_string(kind)}
              >
                {Kind.get(kind).label}
              </option>
            </select>
            <.errors field={@form[:kind]} />
          </label>
          <details id="card-details" phx-mounted={JS.ignore_attributes("open")}>
            <summary>Idea and working directory</summary>
            <.field field={@form[:body]} type="textarea" label="Idea" placeholder={kind_hint(@form)} />
            <small>{kind_hint(@form)}</small>
            <.field field={@form[:cwd]} label="Working directory" required />
          </details>
          <button type="submit">Add card</button>
        </.form>
        <article
          :for={card <- Enum.filter(@cards, &(&1.column == column))}
          id={"card-#{card.id}"}
          class="kanban-card"
          draggable="true"
          data-card-id={card.id}
          data-kind={card.kind}
          data-stop={column in [:agent, :awaiting_user]}
        >
          <.link patch={detail_path(card)}>{card.title}</.link>
          <span class="badge kind-badge">{Kind.get(card.kind).label}</span>
          <.status_badge :if={card.run} status={status(card.run)} />
          <span :if={column == :archive} class="badge">{if card.run && card.run.kind == "pi" &&
                                                             card.run.session_id,
                                                           do: "session saved",
                                                           else: "no saved session"}</span>
          <span :if={column == :awaiting_user && open_round(card)} class="badge">{length(
            open_round(card).questions
          )} questions</span>
          <div :if={column == :agent && pending?(card)} class="banner banner-warn">
            Answers not delivered or feedback not yet confirmed. A timed-out delivery may have arrived; inspect the run before retrying.
            <button type="button" phx-click="retry" phx-value-id={card.id}>Retry</button>
          </div>
        </article>
      </section>
    </div>
    <aside :if={@card} class="kanban-panel" id="card-panel">
      <.link patch="/kanban">Close</.link>
      <h2>{@card.title}</h2>
      <%= case @live_action do %>
        <% :answer -> %>
          <.live_component
            module={Jarvis2Web.KanbanLive.AnswerForm}
            id={"answer-#{@card.id}"}
            card={@card}
            round={open_round(@card)}
          />
        <% :reopen -> %>
          <h3 :if={@card.column == :archive}>Restore from archive</h3>
          <h3>Current {Kind.noun(@card.kind)}</h3><pre>{@card.deliverable}</pre>
          <.form for={%{}} id="reopen-form" phx-change="feedback" phx-submit="reopen">
            <label>What should change? <textarea name="feedback" required>{@feedback}</textarea></label>
            <span>{byte_size(@feedback)} / 1000 bytes</span>
            <button type="submit">{if @card.column == :archive, do: "Restore", else: "Reopen"}</button>
            <.link patch="/kanban">Cancel</.link>
          </.form>
        <% _ -> %>
          <p>{@card.body}</p><p>Working directory: <code>{@card.cwd}</code></p>
          <section :for={round <- Enum.sort_by(@card.rounds, & &1.number)}>
            <h3>Round {round.number} ({round.status})</h3>
            <div :for={q <- round.questions}>
              <strong>{q["id"]} — {q["title"]}</strong><p>{q["body"]}</p>
              <p :if={round.answers[q["id"]]}>
                Answer: {round.answers[q["id"]]["text"]}
                <span :if={round.answers[q["id"]]["note"]}>({round.answers[q["id"]]["note"]})</span>
              </p>
            </div>
          </section>
          <section :for={feedback <- @card.feedback}>
            <h3>Reopen feedback</h3><p>{feedback.text}</p>
          </section>
          <section :if={@card.deliverable}>
            <h3>{String.capitalize(Kind.noun(@card.kind))}</h3>
            <div id={"deliverable-#{@card.id}"} phx-hook="Copy">
              <button type="button">Copy</button><pre>{@card.deliverable}</pre>
            </div>
          </section>
      <% end %>
    </aside>
    """
  end
end
