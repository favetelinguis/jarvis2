defmodule Jarvis2Web.Components do
  @moduledoc "Small stateless function components shared by every page."
  use Phoenix.Component

  attr(:status, :any, default: nil)

  def status_badge(assigns) do
    ~H"""
    <span class={["badge", "badge-#{@status || "unknown"}"]}>{@status || "unknown"}</span>
    """
  end

  attr(:live, :boolean, required: true)

  def live_badge(assigns) do
    ~H"""
    <span class={["badge", if(@live, do: "badge-live", else: "badge-dry")]}>
      Live: {if @live, do: "on", else: "off (dry-run)"}
    </span>
    """
  end

  attr(:field, Phoenix.HTML.FormField, required: true)
  attr(:label, :string, required: true)
  attr(:type, :string, default: "text")
  attr(:options, :list, default: [])
  attr(:rest, :global, include: ~w(rows placeholder required))

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

  attr(:field, Phoenix.HTML.FormField, required: true)

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
