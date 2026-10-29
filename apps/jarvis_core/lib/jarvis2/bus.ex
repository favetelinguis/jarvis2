defmodule Jarvis2.Bus do
  @moduledoc "Process-local publish/subscribe for Herdr and MCP events."

  def subscribe(topic), do: Phoenix.PubSub.subscribe(Jarvis2.PubSub, topic)
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(Jarvis2.PubSub, topic)

  def publish(topic, event),
    do: Phoenix.PubSub.local_broadcast(Jarvis2.PubSub, topic, {:jarvis2, topic, event})
end
