defmodule Jarvis2.FleetTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.{Fleet, Journal}
  alias Jarvis2.Herdr.ExecutionGuard

  @caller %{pane: "w1:p1", workspace: "w1"}

  test "audit records the outcome of each result kind without altering it" do
    results = [
      {{:error, %{code: "disabled"}}, :refused},
      {{:ok, %{pane_id: "w1:p2"}}, :ok},
      {{:error, %{code: "prompt_cycle_refused"}}, :refused},
      {{:error, %{code: "rate_limited"}}, :refused},
      {{:error, "execution rate limit exceeded"}, :refused},
      {{:error, %{code: "timeout"}}, :error},
      {{:error, "pane creation was rejected"}, :error}
    ]

    for {result, _} <- results,
        do:
          assert(
            Fleet.audit(result, "fleet.prompt", @caller, %{text: "secret words"}, []) == result
          )

    events = Journal.recent(source: :mcp)
    assert Enum.map(events, & &1.outcome) == Enum.map(results, &elem(&1, 1))
    assert hd(events).payload == %{"caller" => "w1:p1", "text" => "[omitted 12 bytes]"}
  end

  test "audit attributes events to the caller's source and run" do
    run_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "run:" <> run_id)

    Fleet.audit({:ok, %{}}, "fleet.spawn_agent", %{pane: "w1:p1", run_id: run_id}, %{},
      source: :ui
    )

    assert_receive {:event, %{source: :ui, run_id: ^run_id, type: "fleet.spawn_agent"}}
  end

  test "the execution guard admits a named system caller but still refuses anonymous ones" do
    guard = start_supervised!({ExecutionGuard, [name: nil]})
    ui = %{system: "ui", pane: "system:ui"}

    assert {:ok, ^ui, lease} = ExecutionGuard.reserve(ui, guard)

    assert {:error, "caller execution is busy or cooling down"} =
             ExecutionGuard.reserve(ui, guard)

    ExecutionGuard.finish(lease, :ok, guard)
    assert {:ok, _, _} = ExecutionGuard.reserve(ui, guard)

    assert {:error, _} = ExecutionGuard.reserve(%{pane: "system:fake"}, guard)
    assert {:error, _} = ExecutionGuard.reserve(%{system: "", pane: "system:x"}, guard)
  end
end
