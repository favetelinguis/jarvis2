defmodule Jarvis2.JSONValue do
  @moduledoc "Ecto type storing any JSON value (not only objects) as encoded text."
  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(value), do: {:ok, value}

  @impl true
  def dump(value), do: Jason.encode(value)

  @impl true
  def load(text) when is_binary(text), do: Jason.decode(text)
end
