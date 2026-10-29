defmodule Jarvis2.Scenarios.Dashboard do
  @moduledoc "Open the authenticated local dashboard in a plugin popup."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Socket}

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
  def handle_info({:jarvis2, "hook:action", %{id: "open-dashboard", body: body}}, state) do
    context = if is_map(body["context"]), do: body["context"], else: %{}
    pane = context["focused_pane_id"]
    caller = if is_binary(pane) and byte_size(pane) <= 128, do: pane, else: "unknown"

    params = %{
      plugin_id: "favetelinguis.jarvis2",
      entrypoint: "dashboard",
      placement: "popup",
      width: "80%",
      height: "80%",
      focus: true,
      env: %{
        "JARVIS2_PORT" => Integer.to_string(Application.get_env(:jarvis2, :port, 4747)),
        "JARVIS2_DASHBOARD_STATE_DIR" => Application.fetch_env!(:jarvis2, :state_dir)
      }
    }

    result =
      Actions.call(:dashboard, "plugin.pane.open", params, server: state.socket, caller: caller)

    outcome = if match?({:ok, _}, result), do: :ok, else: :error
    if outcome == :error, do: Logger.warning("Herdr dashboard action failed")
    Jarvis2.Bus.publish("scenario:dashboard", %{outcome: outcome})
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
