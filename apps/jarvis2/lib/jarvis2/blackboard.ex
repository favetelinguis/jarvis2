defmodule Jarvis2.Blackboard do
  @moduledoc "Notes shared between agents and the UI, bounded to 256 keys of at most 16 KiB each."
  import Ecto.Query

  alias Jarvis2.Blackboard.Entry
  alias Jarvis2.Repo

  @max_entries 256
  @topic "blackboard"

  def topic, do: @topic

  @doc "Returns `:ok`, `{:error, :full}` or `{:error, :invalid}`."
  def put(key, value, run_id \\ nil) do
    attrs = %{key: key, value: value, updated_by_run_id: run_id}

    Repo.transaction(fn ->
      entry = if is_binary(key), do: Repo.get_by(Entry, key: key)

      if is_nil(entry) and Repo.aggregate(Entry, :count) >= @max_entries,
        do: Repo.rollback(:full)

      case Repo.insert_or_update(Entry.changeset(entry || %Entry{}, attrs)) do
        {:ok, _} -> :ok
        {:error, _} -> Repo.rollback(:invalid)
      end
    end)
    |> case do
      {:ok, :ok} ->
        broadcast()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Removes a key; returns `:ok` whether or not it existed."
  def delete(key) do
    Repo.delete_all(from e in Entry, where: e.key == ^key)
    broadcast()
    :ok
  end

  @doc "All entries (with their metadata), ordered by key."
  def list_entries, do: Entry |> order_by(:key) |> Repo.all()

  defp broadcast, do: Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, @topic, :blackboard_changed)

  def get(key) do
    case Repo.get_by(Entry, key: key) do
      %Entry{value: value} -> {:ok, value}
      nil -> :error
    end
  end

  def list, do: Entry |> order_by(:key) |> Repo.all() |> Map.new(&{&1.key, &1.value})
end
