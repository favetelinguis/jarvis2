defmodule Jarvis2.Journal do
  @moduledoc """
  Append-only timeline of everything that happened: Herdr events, MCP tool calls, UI actions and
  automations. Payloads are redacted before they are stored, and each recorded event is
  broadcast on `"events"` so live views can append it.
  """
  import Ecto.Query
  require Logger

  alias Jarvis2.Journal.Event
  alias Jarvis2.{Redact, Repo}

  @topic "events"
  @default_limit 200
  @max_limit 1_000

  def topic, do: @topic

  @doc "Records an event. Journalling is best effort: a failing write never breaks the caller."
  def record(attrs) do
    attrs = Map.update(attrs, :payload, %{}, &Redact.payload/1)

    case Repo.insert(Event.changeset(%Event{}, attrs)) do
      {:ok, event} ->
        Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, @topic, {:event, event})
        {:ok, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  rescue
    error ->
      Logger.warning("journal write failed: #{inspect(error.__struct__)}")
      {:error, :unavailable}
  end

  @doc "Most recent events, oldest first. Filters: `:source`, `:type`, `:run_id`, `:limit`."
  def recent(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit)

    opts
    |> query()
    |> order_by(desc: :id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  def count(opts \\ []), do: opts |> query() |> Repo.aggregate(:count)

  @doc "Plain map used by MCP resources and the UI."
  def to_map(%Event{} = event) do
    %{
      id: event.id,
      run_id: event.run_id,
      source: event.source,
      type: event.type,
      outcome: event.outcome,
      payload: event.payload,
      at: DateTime.to_iso8601(event.inserted_at)
    }
  end

  @doc "Deletes events older than `:max_age_days` and everything beyond the newest `:max_rows`."
  def prune(opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :max_age_days, 30), :day)
    max_rows = Keyword.get(opts, :max_rows, 50_000)

    {aged, _} = Repo.delete_all(from(e in Event, where: e.inserted_at < ^cutoff))

    oldest_kept =
      Repo.one(
        from(e in Event, order_by: [desc: e.id], offset: ^max_rows, limit: 1, select: e.id)
      )

    {excess, _} =
      if oldest_kept,
        do: Repo.delete_all(from(e in Event, where: e.id <= ^oldest_kept)),
        else: {0, nil}

    aged + excess
  end

  defp query(opts) do
    Enum.reduce(opts, Event, fn
      {:source, source}, query -> where(query, [e], e.source == ^source)
      {:type, type}, query -> where(query, [e], e.type == ^type)
      {:run_id, run_id}, query -> where(query, [e], e.run_id == ^run_id)
      _, query -> query
    end)
  end
end
