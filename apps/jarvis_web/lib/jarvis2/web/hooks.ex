defmodule Jarvis2.Web.Hooks do
  @moduledoc false
  require Logger

  @context_fields ~w(workspace_id tab_id focused_pane_id focused_pane_agent focused_pane_status invocation_source link_handler_id)

  def accept(kind, id, body) do
    event = %{delivery: "hook", kind: kind, id: id, body: body}
    Logger.info("Herdr hook source=hook kind=#{inspect(kind)} id=#{inspect(id)}")
    log_action(kind, id, body)
    Jarvis2.State.record_event(event)
    Jarvis2.Bus.publish("hook:" <> kind, event)
    if kind == "event", do: Jarvis2.Herdr.Mirror.invalidate()
    :ok
  end

  defp log_action("action", "probe-context", %{"context" => context}) when is_map(context) do
    safe =
      context
      |> Map.take(@context_fields)
      |> Map.filter(fn {_key, value} -> is_binary(value) and byte_size(value) <= 256 end)

    Logger.info("Herdr context probe: #{Jason.encode!(safe, pretty: true)}")
  end

  defp log_action("action", id, %{"clicked_url" => url})
       when id in ["issue-link", "docs-link"] and is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) ->
        safe = URI.to_string(%URI{scheme: scheme, host: host, path: path})
        Logger.info("Herdr link #{inspect(id)} url=#{inspect(String.slice(safe, 0, 2_048))}")

      _ ->
        Logger.info("Herdr link #{inspect(id)} has an invalid URL")
    end
  end

  defp log_action(_, _, _), do: :ok
end
