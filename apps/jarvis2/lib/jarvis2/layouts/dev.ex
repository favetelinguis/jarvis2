defmodule Jarvis2.Layouts.Dev do
  @moduledoc "Create a new developer tab without replacing existing panes."
  require Logger
  alias Jarvis2.Herdr.{Actions, Client, Mirror, Socket}
  alias Jarvis2.MCP.Identity

  def create("dev", %{pane: pane, workspace: workspace}) do
    mirror = Application.get_env(:jarvis2, :mirror, Mirror)
    view = Mirror.get(mirror)
    caller = Identity.resolve(%{"x-herdr-pane" => pane, "x-herdr-workspace" => workspace}, view)
    cwd = caller.cwd

    if caller.pane != "unknown" and is_binary(cwd) and byte_size(cwd) <= 4_096 and
         Path.type(cwd) == :absolute and File.dir?(cwd) do
      root = layout(cwd)
      params = %{workspace_id: caller.workspace, tab_label: "dev", focus: false, root: root}
      Logger.info("Herdr dev layout caller=#{inspect(caller.pane)} panes=editor,tests,agent")
      server = Application.get_env(:jarvis2, :herdr_socket, Socket)

      case action("layout.apply", params,
             caller: caller.pane,
             server: server
           ) do
        {:ok, %{"type" => "layout_apply", "layout" => %{"tab_id" => tab}} = result}
        when is_binary(tab) and tab != "" ->
          {updated, demo} = result |> demonstrate(view, caller, server) |> Map.pop(:layout)
          result = if updated, do: Map.put(result, "layout", updated), else: result
          Logger.info("Herdr layout demo status=#{demo.status}")
          {:ok, Map.put(result, "demo", demo)}

        {:ok, _} ->
          {:error,
           "unrecognized layout response; a tab may have been created; inspect before retrying"}

        {:error, %{code: "disabled"} = error} ->
          {:error, error}

        {:error, _} ->
          {:error,
           "Herdr layout request failed; a tab may have been created; inspect before retrying"}
      end
    else
      {:error, "caller or working directory is unavailable or stale"}
    end
  end

  def create(_, _), do: {:error, "unknown layout or caller"}

  defp demonstrate(result, view, caller, server) do
    try do
      do_demonstrate(result, view, caller, server)
    rescue
      _ -> unconfirmed(result)
    catch
      :exit, _ -> unconfirmed(result)
    end
  end

  defp unconfirmed(%{"layout" => %{"tab_id" => tab}}) when is_binary(tab),
    do: %{status: "unconfirmed", tab_id: tab}

  defp unconfirmed(_), do: %{status: "unconfirmed"}

  defp do_demonstrate(%{"type" => "layout_apply", "layout" => created}, view, caller, server) do
    if fresh_layout?(created, view, caller.workspace, caller.cwd) do
      tab = created["tab_id"]

      case Client.export_layout(tab, server: server, timeout: 2_000) do
        {:ok, %{"type" => "layout_export", "layout" => ^created}} ->
          set_ratio(created, caller.pane, server)

        _ ->
          %{status: "skipped", reason: "export_failed_or_changed", tab_id: tab}
      end
    else
      %{status: "skipped", reason: "unsafe_create_response"}
    end
  end

  defp do_demonstrate(_, _, _, _), do: %{status: "skipped", reason: "unsafe_create_response"}

  defp set_ratio(created, caller, server) do
    tab = created["tab_id"]
    params = %{tab_id: tab, path: [], ratio: 0.65}

    case action("layout.set_split_ratio", params,
           caller: caller,
           server: server,
           timeout: 2_000
         ) do
      {:ok, %{"type" => "layout_split_ratio_set", "layout" => updated}} ->
        if ratio_updated?(created, updated) do
          %{status: "complete", tab_id: tab, root_ratio: 0.65, layout: updated}
        else
          %{status: "unconfirmed", tab_id: tab}
        end

      _ ->
        %{status: "unconfirmed", tab_id: tab}
    end
  end

  defp action(method, params, opts) do
    try do
      Actions.call(:declarative_layout, method, params, opts)
    rescue
      _ -> {:error, %{code: "disconnected"}}
    catch
      :exit, _ -> {:error, %{code: "disconnected"}}
    end
  end

  defp fresh_layout?(
         %{"workspace_id" => workspace, "tab_id" => tab, "zoomed" => false, "root" => root},
         %{stale: false, snapshot: %{"tabs" => tabs, "panes" => panes}},
         workspace,
         cwd
       )
       when is_binary(tab) and tab != "" and is_list(tabs) and is_list(panes) do
    valid_ids =
      Enum.all?(tabs, &(is_map(&1) and is_binary(&1["tab_id"]))) and
        Enum.all?(panes, &(is_map(&1) and is_binary(&1["pane_id"])))

    old_tabs = MapSet.new(Enum.filter(tabs, &is_map/1), & &1["tab_id"])
    old_panes = MapSet.new(Enum.filter(panes, &is_map/1), & &1["pane_id"])

    case created_panes(root, cwd) do
      [a, b, c] = ids ->
        valid_ids and not MapSet.member?(old_tabs, tab) and
          Enum.all?(ids, &(is_binary(&1) and &1 != "" and not MapSet.member?(old_panes, &1))) and
          length(Enum.uniq([a, b, c])) == 3

      _ ->
        false
    end
  end

  defp fresh_layout?(_, _, _, _), do: false

  defp created_panes(
         %{
           "type" => "split",
           "direction" => "right",
           "ratio" => ratio,
           "first" => %{"type" => "pane", "pane_id" => a, "label" => "editor", "cwd" => cwd},
           "second" => %{
             "type" => "split",
             "direction" => "down",
             "ratio" => inner,
             "first" => %{"type" => "pane", "pane_id" => b, "label" => "tests", "cwd" => cwd},
             "second" => %{"type" => "pane", "pane_id" => c, "label" => "agent", "cwd" => cwd}
           }
         },
         cwd
       )
       when is_number(ratio) and is_number(inner) and abs(ratio - 0.55) < 0.001 and
              abs(inner - 0.5) < 0.001,
       do: [a, b, c]

  defp created_panes(_, _), do: nil

  defp ratio_updated?(created, %{"workspace_id" => workspace, "tab_id" => tab, "root" => root})
       when is_map(root) do
    ratio = root["ratio"]

    workspace == created["workspace_id"] and tab == created["tab_id"] and
      is_number(ratio) and abs(ratio - 0.65) < 0.001 and
      Map.delete(root, "ratio") == Map.delete(created["root"], "ratio")
  end

  defp ratio_updated?(_, _), do: false

  defp layout(cwd) do
    pane = fn label -> %{type: "pane", label: label, cwd: cwd} end

    %{
      type: "split",
      direction: "right",
      ratio: 0.55,
      first: pane.("editor"),
      second: %{
        type: "split",
        direction: "down",
        ratio: 0.5,
        first: pane.("tests"),
        second: pane.("agent")
      }
    }
  end
end
