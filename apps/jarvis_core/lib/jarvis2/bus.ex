defmodule Jarvis2.Bus do
  @moduledoc "Process-local publish/subscribe for Herdr and MCP events."

  def subscribe(topic), do: Registry.register(Jarvis2.Registry, topic, nil)
  def unsubscribe(topic), do: Registry.unregister(Jarvis2.Registry, topic)

  def publish(topic, event) do
    Registry.dispatch(Jarvis2.Registry, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:jarvis2, topic, event})
    end)

    :ok
  end
end
