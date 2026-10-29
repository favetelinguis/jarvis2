defmodule Jarvis2.Redact do
  @moduledoc """
  Reduces arbitrary terms to bounded, JSON-safe data before they are persisted.

  Free-form text keys (prompts, commands, summaries, values) are replaced by their size, and
  anything that looks like a credential is masked.
  """

  @secret_key ~r/token|secret|password|authorization|api[_-]?key/i
  @content_keys ~w(text command prompt summary body code value message matched_line task)
  @max_string 256
  @max_items 32
  @max_depth 6

  def payload(term, depth \\ 0)

  def payload(map, depth) when is_map(map) and not is_struct(map) do
    if depth >= @max_depth do
      "[truncated]"
    else
      map
      |> Enum.take(@max_items)
      |> Map.new(fn {key, value} -> {to_string(key), field(to_string(key), value, depth)} end)
    end
  end

  def payload(list, depth) when is_list(list) do
    if depth >= @max_depth,
      do: "[truncated]",
      else: list |> Enum.take(@max_items) |> Enum.map(&payload(&1, depth + 1))
  end

  def payload(text, _depth) when is_binary(text), do: text(text)

  def payload(value, _depth) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  def payload(value, _depth) when is_atom(value), do: Atom.to_string(value)
  def payload(other, _depth), do: other |> inspect(limit: 8) |> text()

  defp field(key, value, depth) do
    cond do
      Regex.match?(@secret_key, key) -> "[redacted]"
      key in @content_keys -> omitted(value)
      true -> payload(value, depth + 1)
    end
  end

  defp omitted(value) when is_binary(value), do: "[omitted #{byte_size(value)} bytes]"
  defp omitted(nil), do: nil
  defp omitted(_), do: "[omitted]"

  defp text(string) do
    string
    |> String.replace(~r/(?i)bearer\s+\S+/, "Bearer [redacted]")
    |> String.replace(~r/[\x00-\x08\x0b\x0c\x0e-\x1f]/, " ")
    |> String.slice(0, @max_string)
  end
end
