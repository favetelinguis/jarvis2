defmodule Jarvis2Web.Components do
  @moduledoc "Small stateless function components shared by every page."
  use Phoenix.Component

  attr(:status, :string, default: nil)

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
end
