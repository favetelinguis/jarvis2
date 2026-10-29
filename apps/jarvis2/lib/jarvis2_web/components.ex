defmodule Jarvis2Web.Components do
  @moduledoc "Small stateless function components shared by every page."
  use Phoenix.Component

  attr :status, :any, default: nil

  def status_badge(assigns) do
    ~H"""
    <span class={["badge", "badge-#{@status || "unknown"}"]}>{@status || "unknown"}</span>
    """
  end

  attr :question, :map, required: true
  attr :run, :map, default: nil

  @doc "A pending question or approval with its answer controls; events go to the parent LiveView."
  def question_card(assigns) do
    ~H"""
    <div class="question" id={"question-#{@question.id}"}>
      <p>
        <strong>{@question.prompt}</strong>
        <span class="muted">
          {@question.kind}
          <span :if={@run}>
            · <.link navigate={"/runs/#{@run.id}"}>{@run.name}</.link>
          </span>
        </span>
      </p>
      <p :if={@question.detail}>{@question.detail}</p>
      <div :if={@question.options != []} class="actions">
        <button
          :for={option <- @question.options}
          type="button"
          phx-click="answer"
          phx-value-id={@question.id}
          phx-value-answer={option}
        >
          {option}
        </button>
      </div>
      <form :if={@question.options == []} phx-submit="answer" class="stack">
        <input type="hidden" name="question_id" value={@question.id} />
        <input type="text" name="answer" placeholder="Your answer" autocomplete="off" />
        <button type="submit">Send</button>
      </form>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :options, :list, default: []
  attr :rest, :global, include: ~w(rows placeholder required)

  def field(%{type: "select"} = assigns) do
    ~H"""
    <label>
      {@label}
      <select id={@field.id} name={@field.name} {@rest}>
        <option :for={option <- @options} value={option} selected={to_string(@field.value) == option}>
          {option}
        </option>
      </select>
      <.errors field={@field} />
    </label>
    """
  end

  def field(%{type: "textarea"} = assigns) do
    ~H"""
    <label>
      {@label}
      <textarea id={@field.id} name={@field.name} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
      <.errors field={@field} />
    </label>
    """
  end

  def field(assigns) do
    ~H"""
    <label>
      {@label}
      <input type={@type} id={@field.id} name={@field.name} value={@field.value} {@rest} />
      <.errors field={@field} />
    </label>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  def errors(assigns) do
    ~H"""
    <span :for={error <- @field.errors} class="field-error">{translate(error)}</span>
    """
  end

  defp translate({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
