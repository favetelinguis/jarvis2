defmodule Jarvis2.Scenarios.LayoutDev do
  @moduledoc "Create a new developer tab without replacing existing panes."
  use GenServer
  require Logger

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(_opts) do
    Jarvis2.Bus.subscribe("hook:action")
    {:ok, %{}}
  end

  defdelegate create(name, caller), to: Jarvis2.Layouts.Dev

  @impl true
  def handle_info({:jarvis2, "hook:action", %{id: "layout-dev", body: body}}, state) do
    context = if is_map(body["context"]), do: body["context"], else: %{}

    result =
      create("dev", %{pane: context["focused_pane_id"], workspace: context["workspace_id"]})

    outcome = if match?({:ok, _}, result), do: :ok, else: :error
    if outcome == :error, do: Logger.warning("Herdr dev layout action failed")
    Jarvis2.Bus.publish("scenario:declarative_layout", %{outcome: outcome})
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
