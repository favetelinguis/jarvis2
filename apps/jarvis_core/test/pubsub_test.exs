defmodule Jarvis2.PubSubTest do
  use ExUnit.Case, async: false

  test "delivers events to subscribers and stops delivery after unsubscribe" do
    topic = "test:bus"
    assert :ok = Phoenix.PubSub.subscribe(Jarvis2.PubSub, topic)

    assert :ok =
             Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, topic, {:jarvis2, topic, %{value: 1}})

    assert_receive {:jarvis2, ^topic, %{value: 1}}

    assert :ok = Phoenix.PubSub.unsubscribe(Jarvis2.PubSub, topic)

    assert :ok =
             Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, topic, {:jarvis2, topic, %{value: 2}})

    refute_receive {:jarvis2, ^topic, _}
  end
end
