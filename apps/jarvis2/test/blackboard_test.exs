defmodule Jarvis2.BlackboardTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.Blackboard

  test "stores any JSON value and distinguishes missing keys from null" do
    assert :error = Blackboard.get("a")
    assert :ok = Blackboard.put("a", %{"answer" => 42})
    assert :ok = Blackboard.put("n", nil)
    assert :ok = Blackboard.put("s", "text")
    assert :ok = Blackboard.put("l", [1, "two"])

    assert {:ok, %{"answer" => 42}} = Blackboard.get("a")
    assert {:ok, nil} = Blackboard.get("n")

    assert Blackboard.list() == %{
             "a" => %{"answer" => 42},
             "n" => nil,
             "s" => "text",
             "l" => [1, "two"]
           }
  end

  test "capacity is bounded but existing keys can be updated" do
    for n <- 1..256, do: assert(:ok = Blackboard.put("key-#{n}", n))
    assert {:error, :full} = Blackboard.put("overflow", true)
    assert :ok = Blackboard.put("key-1", "updated")
    assert {:ok, "updated"} = Blackboard.get("key-1")
  end

  test "rejects invalid keys and oversized values" do
    assert {:error, :invalid} = Blackboard.put("", 1)
    assert {:error, :invalid} = Blackboard.put(nil, 1)
    assert {:error, :invalid} = Blackboard.put(String.duplicate("k", 257), 1)
    assert {:error, :invalid} = Blackboard.put("big", String.duplicate("x", 16_384))
    assert :ok = Blackboard.put("fits", String.duplicate("x", 16_000))
  end

  test "the same key can be written concurrently" do
    1..20
    |> Task.async_stream(&Blackboard.put("shared", &1), max_concurrency: 8)
    |> Stream.run()

    assert {:ok, value} = Blackboard.get("shared")
    assert value in 1..20
    assert map_size(Blackboard.list()) == 1
  end
end
