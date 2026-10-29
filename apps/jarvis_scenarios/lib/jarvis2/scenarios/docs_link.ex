defmodule Jarvis2.Scenarios.DocsLink do
  @moduledoc "Open a HexDocs URL in a plugin-owned text-browser popup."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Socket}
  alias Jarvis2.MCP.Identity

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    Jarvis2.Bus.subscribe("hook:action")

    {:ok,
     %{
       socket: Keyword.get(opts, :socket, Application.get_env(:jarvis2, :herdr_socket, Socket)),
       last: nil
     }}
  end

  @impl true
  def handle_info({:jarvis2, "hook:action", %{id: "docs-link", body: body}}, state) do
    context = if is_map(body["context"]), do: body["context"], else: %{}

    caller =
      Identity.resolve(%{
        "x-herdr-pane" => context["focused_pane_id"],
        "x-herdr-workspace" => context["workspace_id"]
      })

    url = body["clicked_url"]
    now = System.monotonic_time(:millisecond)

    cond do
      caller.pane == "unknown" or not valid_url?(url) ->
        Logger.warning("Herdr docs link rejected")
        {:noreply, state}

      state.last && now - state.last < 2_000 ->
        Logger.warning("Herdr docs link rate limited")
        {:noreply, state}

      true ->
        params = %{
          plugin_id: "favetelinguis.jarvis2",
          entrypoint: "docs",
          placement: "popup",
          focus: true,
          env: %{"JARVIS2_DOCS_URL" => url}
        }

        result =
          Actions.call(:docs_link, "plugin.pane.open", params,
            caller: caller.pane,
            server: state.socket,
            timeout: 5_000
          )

        outcome = if match?({:ok, _}, result), do: :ok, else: :error
        Jarvis2.Bus.publish("scenario:docs_link", %{pane: caller.pane, outcome: outcome})
        {:noreply, %{state | last: now}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp valid_url?(url) when is_binary(url) and byte_size(url) in 1..2_048 do
    uri = URI.parse(url)

    uri.scheme == "https" and uri.host == "hexdocs.pm" and uri.port == 443 and
      uri.authority in ["hexdocs.pm", "hexdocs.pm:443"] and is_nil(uri.userinfo) and
      is_binary(uri.path) and String.starts_with?(uri.path, "/") and
      not String.match?(url, ~r/[\p{C}\s]/u)
  end

  defp valid_url?(_), do: false
end
