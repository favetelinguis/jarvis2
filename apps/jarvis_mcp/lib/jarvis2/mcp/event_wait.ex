defmodule Jarvis2.MCP.EventWait do
  @moduledoc false

  def wait(match, timeout_s)
      when is_map(match) and is_integer(timeout_s) and timeout_s in 1..110 do
    type = match["type"] || match[:type]
    filters = Map.get(match, "filters", Map.get(match, :filters, %{}))

    if valid_type?(type) and valid_filters?(filters) do
      topic = "herdr:" <> type
      :ok = Jarvis2.Bus.subscribe(topic)

      try do
        receive_matching(topic, filters, System.monotonic_time(:millisecond) + timeout_s * 1_000)
      after
        Jarvis2.Bus.unsubscribe(topic)
      end
    else
      {:error, "invalid event type or filters"}
    end
  end

  def wait(_, _), do: {:error, "timeout_s must be between 1 and 110 seconds"}

  defp receive_matching(topic, filters, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:ok, %{matched: false, timeout: true}}
    else
      receive do
        {:jarvis2, ^topic, %{data: data} = event} when is_map(data) ->
          if Enum.all?(filters, fn {key, value} ->
               Map.has_key?(data, to_string(key)) and Map.get(data, to_string(key)) == value
             end) do
            {:ok, %{matched: true, event: event}}
          else
            receive_matching(topic, filters, deadline)
          end
      after
        remaining -> {:ok, %{matched: false, timeout: true}}
      end
    end
  end

  defp valid_type?(type),
    do:
      is_binary(type) and byte_size(type) <= 128 and
        Regex.match?(~r/\A(?:workspace|tab|pane|layout|worktree)\.[a-z_]+\z/, type)

  defp valid_filters?(filters) when is_map(filters) and map_size(filters) <= 16 do
    Enum.all?(filters, fn {key, value} ->
      is_binary(key) and byte_size(key) in 1..64 and
        (is_nil(value) or is_boolean(value) or is_number(value) or
           (is_binary(value) and byte_size(value) <= 256))
    end)
  end

  defp valid_filters?(_), do: false
end
