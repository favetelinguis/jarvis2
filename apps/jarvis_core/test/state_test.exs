defmodule Jarvis2.StateTest do
  use ExUnit.Case, async: false

  test "blackboard stores values and distinguishes missing keys" do
    key = "test-#{System.unique_integer([:positive])}"
    assert :error = Jarvis2.State.get(key)
    assert :ok = Jarvis2.State.put(key, %{"answer" => 42})
    assert {:ok, %{"answer" => 42}} = Jarvis2.State.get(key)
    assert Jarvis2.State.list()[key] == %{"answer" => 42}
  end

  test "blackboard capacity is bounded but existing keys can be updated" do
    {:ok, state} = start_supervised({Jarvis2.State, [name: nil]})
    for n <- 1..256, do: assert(:ok = Jarvis2.State.put("key-#{n}", n, state))
    assert {:error, :full} = Jarvis2.State.put("overflow", true, state)
    assert :ok = Jarvis2.State.put("key-1", "updated", state)
  end

  test "event and journal history is bounded and ordered" do
    {:ok, state} = start_supervised({Jarvis2.State, [name: nil]})

    for index <- 1..205 do
      assert :ok = Jarvis2.State.record_event(index, state)
      assert :ok = Jarvis2.State.journal(index, state)
    end

    assert Jarvis2.State.events(state) == Enum.to_list(6..205)
    assert Jarvis2.State.recent_journal(state) == Enum.to_list(6..205)
    assert Jarvis2.State.mcp_call_count(state) == 205
  end
end
