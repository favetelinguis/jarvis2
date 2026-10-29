defmodule Jarvis2.JournalTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.Journal

  test "records redacted events in order, filtered by source" do
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, Journal.topic())

    assert {:ok, %{id: first}} =
             Journal.record(%{
               source: :mcp,
               type: "tool.log",
               payload: %{
                 caller: %{pane: "w1:p1"},
                 args: %{message: "private words", api_key: "abc", level: "info"}
               }
             })

    assert_receive {:event, %{id: ^first}}
    {:ok, _} = Journal.record(%{source: :herdr, type: "pane.focused"})
    {:ok, _} = Journal.record(%{source: :mcp, type: "tool.whoami", outcome: :error})

    assert [%{type: "tool.log"} = logged, %{type: "tool.whoami", outcome: :error}] =
             Journal.recent(source: :mcp)

    assert logged.payload["args"] == %{
             "message" => "[omitted 13 bytes]",
             "api_key" => "[redacted]",
             "level" => "info"
           }

    assert Journal.count(source: :mcp) == 2
    assert Journal.count() == 3
    assert [%{type: "pane.focused"}] = Journal.recent(source: :herdr)
    assert length(Journal.recent(limit: 2)) == 2
  end

  test "rejects invalid events without raising" do
    assert {:error, %Ecto.Changeset{}} = Journal.record(%{source: :mcp})
  end

  test "pruning removes events older than the retention age and rows beyond the cap" do
    old = DateTime.add(DateTime.utc_now(), -40, :day)

    Repo.insert!(%Journal.Event{source: :mcp, type: "old", payload: %{}, inserted_at: old})
    for n <- 1..5, do: {:ok, _} = Journal.record(%{source: :mcp, type: "new-#{n}"})

    assert Journal.prune(max_rows: 3) == 3
    assert Enum.map(Journal.recent(), & &1.type) == ["new-3", "new-4", "new-5"]
  end
end
