defmodule Jarvis2.Fleet do
  @moduledoc """
  The one place where agents, panes and layouts are changed. MCP tools and the UI both call it, so
  the live/dry-run gates and per-caller guards behind `Jarvis2.Herdr.Actions` apply to either, and
  every attempt leaves an audit row in the journal with its outcome.
  """
  alias Jarvis2.Herdr.Actions
  alias Jarvis2.Journal

  def prompt(caller, target, text, wait, opts \\ []) do
    caller
    |> Actions.prompt(target, text, wait, opts)
    |> audit("fleet.prompt", caller, %{target: target, text: text, wait: wait}, opts)
  end

  def spawn_agent(caller, args, opts \\ []) do
    caller
    |> Actions.spawn_agent(args, opts)
    |> audit("fleet.spawn_agent", caller, args, opts)
  end

  def run_command(caller, args, opts \\ []) do
    caller
    |> Actions.run_command(args, opts)
    |> audit("fleet.run_command", caller, args, opts)
  end

  def apply_layout(name, caller, opts \\ []) do
    name
    |> Jarvis2.Layouts.Dev.create(caller)
    |> audit("fleet.apply_layout", caller, %{name: name}, opts)
  end

  @doc "Writes a `fleet.*` event for an attempted change and returns `result` untouched."
  def audit(result, type, caller, payload, opts) do
    Journal.record(%{
      source: Keyword.get(opts, :source, :mcp),
      type: type,
      outcome: outcome(result),
      run_id: caller[:run_id],
      payload: Map.merge(%{caller: caller[:pane]}, Map.new(payload))
    })

    result
  end

  defp outcome({:ok, %{dry_run: true}}), do: :dry_run
  defp outcome({:ok, _}), do: :ok

  defp outcome({:error, %{code: code}}) when is_binary(code), do: refusal(code)
  defp outcome({:error, message}) when is_binary(message), do: refusal(message)
  defp outcome(_), do: :error

  defp refusal(reason) do
    if reason =~ ~r/refused|rate.limit|busy|cooling|capacity|guard_unavailable|unavailable/,
      do: :refused,
      else: :error
  end
end
