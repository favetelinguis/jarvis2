defmodule Jarvis2Web.KanbanLive.AnswerForm do
  use Phoenix.LiveComponent
  alias Jarvis2.Kanban
  alias Jarvis2.Kanban.Round

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    choose(socket, id, "recommended", fn q -> q["recommended"] end)
  end

  # Not "value": the LiveView client overwrites phx-value-value with the button's own (empty) value.
  def handle_event("option", %{"id" => id, "option" => value}, socket) do
    choose(socket, id, "option", fn _ -> value end)
  end

  def handle_event("accept_all", _, %{assigns: %{round: %Round{} = round}} = socket) do
    answers =
      Enum.reduce(round.questions, round.answers, fn q, acc ->
        current = Map.get(acc, q["id"], %{})

        if answered?(q, current),
          do: acc,
          else:
            Map.put(acc, q["id"], %{
              "kind" => "recommended",
              "text" => q["recommended"],
              "note" => current["note"] || ""
            })
      end)

    save(socket, answers)
  end

  def handle_event("draft", %{"answers" => answers} = params, socket) when is_map(answers) do
    answers =
      case params["_target"] do
        ["answers", id, "text"] when is_map_key(answers, id) ->
          if is_map(answers[id]), do: put_in(answers, [id, "kind"], "custom"), else: answers

        _ ->
          answers
      end

    save(socket, answers)
  end

  def handle_event("submit", _, %{assigns: %{round: %Round{} = round}} = socket) do
    case Kanban.submit_answers(round) do
      {:ok, _} -> {:noreply, push_patch(socket, to: "/kanban")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event(_, _, socket),
    do: {:noreply, put_flash(socket, :error, "The round is no longer open.")}

  defp choose(%{assigns: %{round: %Round{} = round}} = socket, id, kind, value) do
    case Enum.find(round.questions, &(&1["id"] == id)) do
      nil ->
        {:noreply, socket}

      q ->
        old = Map.get(round.answers, id, %{})

        answers =
          Map.put(round.answers, id, %{
            "kind" => kind,
            "text" => value.(q),
            "note" => old["note"] || ""
          })

        save(socket, answers)
    end
  end

  defp choose(socket, _, _, _), do: {:noreply, socket}

  defp save(%{assigns: %{round: %Round{} = round}} = socket, answers) do
    case Kanban.save_draft(round, answers) do
      {:ok, updated} -> {:noreply, assign(socket, :round, updated)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp save(socket, _), do: {:noreply, socket}

  defp answered?(q, answer) do
    Round.complete?(%Round{questions: [q], answers: %{q["id"] => answer}})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"answer-widget-#{@id}"} phx-hook="AnswerKeys">
      <p :if={!@round}>This round is no longer open.</p>
      <%= if @round do %>
        <button type="button" id="accept-all" phx-click="accept_all" phx-target={@myself}>Accept all remaining recommendations</button>
        <.form for={%{}} id="answer-form" phx-change="draft" phx-submit="submit" phx-target={@myself}>
          <section :for={q <- @round.questions} class="question" tabindex="0" data-question={q["id"]}>
            <% answer = Map.get(@round.answers, q["id"], %{}) %>
            <h3>
              {q["id"]} — {q["title"]} <span :if={answered?(q, answer)} class="badge">Answered</span>
            </h3>
            <p class="question-body">{q["body"]}</p><p>Recommended: {q["recommended"]}</p>
            <div class="answer-choices" role="group" aria-label={"Choices for #{q["id"]}"}>
              <button
                type="button"
                id={"accept-#{q["id"]}"}
                phx-click="accept"
                phx-value-id={q["id"]}
                phx-target={@myself}
                aria-pressed={to_string(answer["kind"] == "recommended")}
              >Accept recommendation</button>
              <button
                :for={option <- q["options"]}
                type="button"
                phx-click="option"
                phx-value-id={q["id"]}
                phx-value-option={option}
                phx-target={@myself}
                aria-pressed={to_string(answer["kind"] == "option" && answer["text"] == option)}
              >{option}</button>
            </div>
            <p :if={q["options"] == []} class="muted">No alternatives provided.</p>
            <input type="hidden" name={"answers[#{q["id"]}][kind]"} value={answer["kind"] || ""} />
            <label>Or write your own answer
            <input name={"answers[#{q["id"]}][text]"} value={answer["text"] || ""} /></label>
            <label>Because… <input name={"answers[#{q["id"]}][note]"} value={answer["note"] || ""} /></label>
          </section>
          <button id="submit-answers" type="submit" disabled={!Round.complete?(@round)}>Submit answers</button>
        </.form>
      <% end %>
    </div>
    """
  end
end
