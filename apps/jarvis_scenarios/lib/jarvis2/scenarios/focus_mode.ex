defmodule Jarvis2.Scenarios.FocusMode do
  @moduledoc "Install or clear this plugin's transient agent view."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Socket}

  defdelegate view(), to: Jarvis2.FocusView

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    Jarvis2.Bus.subscribe("hook:action")
    {:ok, %{socket: Keyword.get(opts, :socket, Socket)}}
  end

  @impl true
  def handle_info({:jarvis2, "hook:action", %{id: action, body: body}}, state)
      when action in ["focus-mode", "focus-mode-off"] do
    context = if is_map(body["context"]), do: body["context"], else: %{}
    pane = context["focused_pane_id"]
    caller = if is_binary(pane) and byte_size(pane) <= 128, do: pane, else: "unknown"

    {method, params} =
      if action == "focus-mode",
        do: {"agent.view.set", Jarvis2.FocusView.view()},
        else: {"agent.view.clear", %{source: Jarvis2.FocusView.view().source}}

    Logger.info(
      "Herdr focus mode action=#{inspect(action)} filter=current-workspace-or-attention sort=attention,recent"
    )

    result = Actions.call(:focus_mode, method, params, server: state.socket, caller: caller)
    outcome = if match?({:ok, _}, result), do: :ok, else: :error

    if outcome == :ok and Application.get_env(:jarvis2, :live, false) and
         :focus_mode in Application.get_env(:jarvis2, :live_scenarios, []) do
      Jarvis2.Scenarios.Restore.record_focus(action == "focus-mode")
    end

    if outcome == :error, do: Logger.warning("Herdr focus mode action failed")
    Jarvis2.Bus.publish("scenario:focus_mode", %{action: action, outcome: outcome})
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
