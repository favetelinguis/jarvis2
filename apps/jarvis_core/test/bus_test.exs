defmodule Jarvis2.BusTest do
  use ExUnit.Case, async: false

  test "delivers events to subscribers and stops delivery after unsubscribe" do
    topic = "test:bus"
    assert :ok = Jarvis2.Bus.subscribe(topic)
    assert :ok = Jarvis2.Bus.publish(topic, %{value: 1})
    assert_receive {:jarvis2, ^topic, %{value: 1}}

    assert :ok = Jarvis2.Bus.unsubscribe(topic)
    assert :ok = Jarvis2.Bus.publish(topic, %{value: 2})
    refute_receive {:jarvis2, ^topic, _}
  end
end
