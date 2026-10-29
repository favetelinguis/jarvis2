defmodule Jarvis2.Scenarios.Restore do
  @moduledoc "Best-effort restore of this plugin's view and short-lived metadata."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Mirror, Socket}

  @max_tokens 64
  @max_file_bytes 65_536
  @ttl_ms 60_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def record_focus(enabled) when is_boolean(enabled), do: record({:focus, enabled})

  def record_token(method, params, pane, view, expires_at) do
    if enabled?(:sidebar_tokens) do
      case token_entry(method, params, pane, view, expires_at) do
        {:ok, entry} -> record({:token, entry})
        :error -> :ok
      end
    end
  end

  defp record(message) do
    server = Application.get_env(:jarvis2, :restore, __MODULE__)

    try do
      GenServer.call(server, {:record, message}, 2_000)
    catch
      :exit, _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    Jarvis2.Bus.subscribe("mirror:updated")
    dir = Keyword.get(opts, :state_dir, Application.fetch_env!(:jarvis2, :state_dir))

    path =
      Keyword.get(opts, :socket_path) || System.get_env("HERDR_SOCKET_PATH") ||
        Path.expand("~/.config/herdr/herdr.sock")

    state = %{
      dir: dir,
      path: path,
      session: nil,
      data: empty(),
      loaded: false,
      mirror: Keyword.get(opts, :mirror, Application.get_env(:jarvis2, :mirror, Mirror)),
      socket: Keyword.get(opts, :socket, Application.get_env(:jarvis2, :herdr_socket, Socket)),
      focus_attempted: false,
      token_attempted: MapSet.new(),
      token_scheduled: false,
      expiry_timer: nil
    }

    send(self(), :bootstrap)
    {:ok, load_session(state)}
  end

  @impl true
  def handle_call({:record, {:focus, enabled}}, _from, state) do
    state = load_session(state)
    data = %{state.data | "focus" => enabled}
    {:reply, :ok, save(%{state | data: data, focus_attempted: true})}
  end

  def handle_call({:record, {:token, entry}}, _from, state) do
    state = load_session(state)
    now = System.system_time(:millisecond)

    tokens =
      state.data["tokens"]
      |> Enum.filter(&(&1["expires_at"] > now))
      |> Enum.reject(&(token_key(&1) == token_key(entry)))

    tokens = Enum.take([entry | tokens], @max_tokens)
    data = %{state.data | "tokens" => tokens}

    {:reply, :ok,
     save(%{
       state
       | data: data,
         token_attempted:
           state.token_attempted
           |> MapSet.intersection(MapSet.new(tokens, &token_key/1))
           |> MapSet.put(token_key(entry))
     })}
  end

  @impl true
  def handle_info(:bootstrap, state), do: {:noreply, restore_from_mirror(state)}

  def handle_info({:jarvis2, "mirror:updated", %{source: source, view: %{stale: false}}}, state) do
    if source == GenServer.whereis(state.mirror),
      do: {:noreply, restore_from_mirror(state)},
      else: {:noreply, state}
  end

  def handle_info(:restore_token, state) do
    state = %{state | token_scheduled: false} |> load_session()

    case Mirror.get(state.mirror) do
      %{stale: false, snapshot: snapshot} = view when is_map(snapshot) ->
        case restore_one_token(state, view) do
          {:attempted, updated} -> {:noreply, schedule_tokens(updated)}
          {:idle, updated} -> {:noreply, updated}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:expire_tokens, marker}, %{expiry_timer: {_, marker}} = state) do
    {:noreply, state |> Map.put(:expiry_timer, nil) |> load_session() |> prune_expired()}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp restore_from_mirror(state) do
    state = load_session(state)

    case Mirror.get(state.mirror) do
      %{stale: false, snapshot: snapshot} when is_map(snapshot) ->
        state |> restore_focus() |> schedule_tokens()

      _ ->
        state
    end
  end

  defp schedule_tokens(%{token_scheduled: false} = state) do
    send(self(), :restore_token)
    %{state | token_scheduled: true}
  end

  defp schedule_tokens(state), do: state

  defp restore_focus(
         %{session: session, focus_attempted: false, data: %{"focus" => true}} = state
       )
       when is_binary(session) do
    if enabled?(:focus_mode) do
      result =
        Actions.call(:focus_mode, "agent.view.set", Jarvis2.FocusView.view(),
          server: state.socket,
          caller: "restore",
          timeout: 2_000
        )

      if match?({:error, _}, result),
        do: Logger.warning("Herdr focus restore failed; not retried")

      %{state | focus_attempted: true}
    else
      state
    end
  end

  defp restore_focus(state), do: state

  defp restore_one_token(%{session: session} = state, view) when is_binary(session) do
    now = System.system_time(:millisecond)

    entry =
      if enabled?(:sidebar_tokens) do
        Enum.find(state.data["tokens"], fn entry ->
          ttl = entry["expires_at"] - now

          ttl in 1..@ttl_ms and not MapSet.member?(state.token_attempted, token_key(entry)) and
            same_pane?(entry, view)
        end)
      end

    if entry do
      params = restored_params(entry, entry["expires_at"] - now)

      method =
        if entry["scope"] == "pane", do: "pane.report_metadata", else: "workspace.report_metadata"

      result =
        Actions.call(:sidebar_tokens, method, params,
          server: state.socket,
          caller: "restore",
          timeout: 2_000
        )

      if match?({:error, _}, result),
        do: Logger.warning("Herdr token restore failed; not retried")

      {:attempted,
       %{state | token_attempted: MapSet.put(state.token_attempted, token_key(entry))}}
    else
      {:idle, state}
    end
  end

  defp restore_one_token(state, _), do: {:idle, state}

  defp same_pane?(entry, %{snapshot: %{"panes" => panes, "agents" => agents}})
       when is_list(panes) and is_list(agents) do
    Enum.count(panes, fn pane ->
      is_map(pane) and pane["pane_id"] == entry["pane"] and
        pane["workspace_id"] == entry["workspace"] and
        pane["terminal_id"] == entry["terminal"]
    end) == 1 and
      agent_identity(agents, entry["pane"], entry["terminal"], entry["workspace"]) ==
        {:ok, entry["agent_kind"], entry["agent_name"]}
  end

  defp same_pane?(_, _), do: false

  defp restored_params(entry, ttl) do
    common = %{source: entry["source"], tokens: %{entry["key"] => entry["value"]}, ttl_ms: ttl}

    if entry["scope"] == "pane",
      do: Map.put(common, :pane_id, entry["pane"]),
      else: Map.put(common, :workspace_id, entry["workspace"])
  end

  defp token_entry(
         method,
         params,
         pane,
         %{
           stale: false,
           snapshot: %{"panes" => panes, "agents" => agents}
         },
         expires_at
       )
       when is_map(params) and is_list(panes) and is_list(agents) and is_integer(expires_at) do
    with [found] <- Enum.filter(panes, &(is_map(&1) and &1["pane_id"] == pane)),
         terminal when is_binary(terminal) and byte_size(terminal) in 1..256 <-
           found["terminal_id"],
         workspace when is_binary(workspace) and byte_size(workspace) in 1..128 <-
           found["workspace_id"],
         {:ok, kind, name} <- agent_identity(agents, pane, terminal, workspace),
         {:ok, scope, source, key, value} <- token_fields(method, params, pane, workspace),
         true <-
           is_binary(pane) and byte_size(pane) in 1..128 and is_binary(value) and
             byte_size(value) <= 512 and expires_at > System.system_time(:millisecond) and
             expires_at <= System.system_time(:millisecond) + @ttl_ms do
      {:ok,
       %{
         "scope" => scope,
         "source" => source,
         "key" => key,
         "value" => value,
         "pane" => pane,
         "terminal" => terminal,
         "workspace" => workspace,
         "agent_kind" => kind,
         "agent_name" => name,
         "expires_at" => expires_at
       }}
    else
      _ -> :error
    end
  end

  defp token_entry(_, _, _, _, _), do: :error

  defp agent_identity(agents, pane, terminal, workspace) do
    if Enum.all?(agents, &is_map/1) do
      case Enum.filter(agents, &(&1["pane_id"] == pane)) do
        [] ->
          {:ok, nil, nil}

        [%{"agent" => kind, "terminal_id" => ^terminal, "workspace_id" => ^workspace} = agent]
        when is_binary(kind) and byte_size(kind) in 1..64 ->
          name = agent["name"]

          if is_nil(name) or (is_binary(name) and byte_size(name) <= 128),
            do: {:ok, kind, name},
            else: :error

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp token_fields(
         "pane.report_metadata",
         %{pane_id: pane, source: "custom:jarvis2", tokens: %{jarvis: value}},
         pane,
         _
       ),
       do: {:ok, "pane", "custom:jarvis2", "jarvis", value}

  defp token_fields(
         "pane.report_metadata",
         %{pane_id: pane, source: "custom:jarvis2-state", tokens: %{agent_state: value}},
         pane,
         _
       ),
       do: {:ok, "pane", "custom:jarvis2-state", "agent_state", value}

  defp token_fields(
         "workspace.report_metadata",
         %{workspace_id: workspace, source: "custom:jarvis2-mcp", tokens: %{last_tool: value}},
         _,
         workspace
       ),
       do: {:ok, "workspace", "custom:jarvis2-mcp", "last_tool", value}

  defp token_fields(_, _, _, _), do: :error

  defp token_key(entry),
    do:
      {entry["scope"], entry["source"], entry["key"],
       if(entry["scope"] == "pane", do: entry["pane"], else: entry["workspace"])}

  defp empty, do: %{"focus" => false, "tokens" => []}

  defp enabled?(scenario),
    do:
      Application.get_env(:jarvis2, :live, false) and
        scenario in Application.get_env(:jarvis2, :live_scenarios, [])

  defp load_session(state) do
    session =
      case File.stat(state.path) do
        {:ok, %{type: :other, inode: inode} = stat} when is_integer(inode) and inode > 0 ->
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary({state.path, stat.major_device, inode, stat.ctime})
          )
          |> Base.encode16(case: :lower)

        _ ->
          nil
      end

    cond do
      session == state.session and state.loaded ->
        state

      is_binary(session) ->
        %{
          state
          | session: session,
            loaded: true,
            data: read_data(state.dir, session),
            focus_attempted: false,
            token_attempted: MapSet.new()
        }
        |> prune_expired()

      true ->
        %{
          state
          | session: nil,
            loaded: false,
            data: empty(),
            focus_attempted: false,
            token_attempted: MapSet.new()
        }
        |> schedule_expiry()
    end
  end

  defp read_data(dir, session) do
    path = Path.join(dir, "restore.json")

    with {:ok, %{type: :regular, size: size, mode: mode}} when size <= @max_file_bytes <-
           File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, contents} <- File.read(path),
         {:ok, %{"version" => 1, "session" => ^session, "focus" => focus, "tokens" => tokens}}
         when is_boolean(focus) and is_list(tokens) and length(tokens) <= @max_tokens <-
           Jason.decode(contents),
         true <- Enum.all?(tokens, &valid_saved_token?/1) do
      %{"focus" => focus, "tokens" => tokens}
    else
      _ -> empty()
    end
  end

  defp valid_saved_token?(entry) when is_map(entry) do
    fields = ~w(scope source key value pane terminal workspace)

    valid =
      Enum.all?(fields, &(is_binary(entry[&1]) and byte_size(entry[&1]) in 1..512)) and
        is_integer(entry["expires_at"]) and
        (is_nil(entry["agent_kind"]) or
           (is_binary(entry["agent_kind"]) and byte_size(entry["agent_kind"]) in 1..64)) and
        (is_nil(entry["agent_name"]) or
           (is_binary(entry["agent_name"]) and byte_size(entry["agent_name"]) <= 128)) and
        (not is_nil(entry["agent_kind"]) or is_nil(entry["agent_name"]))

    allowed =
      {entry["scope"], entry["source"], entry["key"]} in [
        {"pane", "custom:jarvis2", "jarvis"},
        {"pane", "custom:jarvis2-state", "agent_state"},
        {"workspace", "custom:jarvis2-mcp", "last_tool"}
      ]

    valid and allowed
  end

  defp valid_saved_token?(_), do: false

  defp prune_expired(state) do
    now = System.system_time(:millisecond)

    tokens =
      Enum.filter(
        state.data["tokens"],
        &(&1["expires_at"] > now and &1["expires_at"] <= now + @ttl_ms)
      )

    attempted = MapSet.intersection(state.token_attempted, MapSet.new(tokens, &token_key/1))
    updated = %{state | data: %{state.data | "tokens" => tokens}, token_attempted: attempted}
    if tokens == state.data["tokens"], do: schedule_expiry(updated), else: save(updated)
  end

  defp schedule_expiry(state) do
    if state.expiry_timer, do: Process.cancel_timer(elem(state.expiry_timer, 0))

    case Enum.map(state.data["tokens"], & &1["expires_at"]) do
      [] ->
        %{state | expiry_timer: nil}

      deadlines ->
        marker = make_ref()
        delay = max(Enum.min(deadlines) - System.system_time(:millisecond), 1)
        timer = Process.send_after(self(), {:expire_tokens, marker}, delay)
        %{state | expiry_timer: {timer, marker}}
    end
  end

  defp save(%{session: nil} = state), do: schedule_expiry(state)

  defp save(state) do
    payload =
      Map.merge(state.data, %{"version" => 1, "session" => state.session}) |> Jason.encode!()

    path = Path.join(state.dir, "restore.json")

    temp =
      Path.join(
        state.dir,
        ".restore-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    result =
      if byte_size(payload) <= @max_file_bytes do
        with {:ok, file} <- File.open(temp, [:write, :binary, :exclusive]) do
          try do
            result =
              try do
                with :ok <- File.chmod(temp, 0o600), do: IO.binwrite(file, payload)
              after
                File.close(file)
              end

            if result == :ok, do: File.rename(temp, path), else: result
          after
            File.rm(temp)
          end
        end
      else
        {:error, :too_large}
      end

    if result != :ok, do: Logger.warning("Herdr restore state could not be saved")
    schedule_expiry(state)
  end
end
