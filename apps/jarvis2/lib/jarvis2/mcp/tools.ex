defmodule Jarvis2.MCP.Tools do
  @moduledoc false
  require Logger
  alias Jarvis2.{Fleet, Questions, Runs}
  alias Jarvis2.Herdr.{Actions, Client, Mirror, Socket}
  alias Jarvis2.MCP.EventWait

  def call("whoami", _args, caller) do
    {:ok, caller}
  end

  def call("log", args, caller) do
    level = value(args, :level)
    message = value(args, :message)

    if byte_size(message) <= 4_096 do
      levels = %{"debug" => :debug, "info" => :info, "warning" => :warning, "error" => :error}

      Logger.log(
        Map.fetch!(levels, level),
        "agent pane=#{inspect(caller.pane)} message=#{inspect(redact(message))}"
      )

      {:ok, %{ok: true}}
    else
      {:error, "message is too long"}
    end
  end

  def call("blackboard_put", args, _caller) do
    key = value(args, :key)
    value = value(args, :value)

    if valid_key?(key) and byte_size(Jason.encode!(value)) <= 16_384 do
      case Jarvis2.Blackboard.put(key, value) do
        :ok -> {:ok, %{ok: true}}
        {:error, :full} -> {:error, "blackboard is full"}
        {:error, :invalid} -> {:error, "invalid key or value is too large"}
      end
    else
      {:error, "invalid key or value is too large"}
    end
  end

  def call("blackboard_get", args, _caller) do
    case Jarvis2.Blackboard.get(value(args, :key)) do
      {:ok, result} -> {:ok, %{found: true, value: result}}
      :error -> {:ok, %{found: false}}
    end
  end

  def call("blackboard_list", _args, _caller), do: {:ok, Jarvis2.Blackboard.list()}

  def call("list_agents", args, _caller) do
    with {:ok, view} <- fresh_view() do
      workspace = value(args, :workspace)

      agents =
        Enum.filter(
          view.snapshot["agents"],
          &(is_nil(workspace) or &1["workspace_id"] == workspace)
        )

      {:ok, %{agents: agents}}
    end
  end

  def call("get_layout", args, _caller) do
    with {:ok, view} <- fresh_view() do
      layout = layout_for(view, value(args, :workspace))

      if value(args, :format) == "tree",
        do: {:ok, %{tree: render_tree(layout)}},
        else: {:ok, layout}
    end
  end

  def call("list_worktrees", args, _caller) do
    with {:ok, view} <- fresh_view() do
      repo = value(args, :repo)
      worktrees = if repo, do: Map.take(view.worktrees, [repo]), else: view.worktrees
      errors = if repo, do: Map.take(view.worktree_errors, [repo]), else: view.worktree_errors
      {:ok, %{worktrees: worktrees, errors: errors}}
    end
  end

  def call("ask_human", args, %{run_id: run_id}) when is_binary(run_id) do
    ask(run_id, :question, %{prompt: value(args, :prompt), options: value(args, :options) || []})
  end

  def call("request_approval", args, %{run_id: run_id}) when is_binary(run_id) do
    ask(run_id, :approval, %{
      prompt: value(args, :action),
      detail: value(args, :detail),
      options: ["approve", "deny"]
    })
  end

  def call("wait_for_answer", args, %{run_id: run_id}) when is_binary(run_id) do
    timeout_s = value(args, :timeout_s) || 30

    if is_integer(timeout_s) and timeout_s in 1..100 do
      case Questions.wait(value(args, :ticket), run_id, timeout_s * 1_000) do
        nil -> {:error, "unknown ticket"}
        question -> {:ok, ticket_status(question)}
      end
    else
      {:error, "timeout_s must be between 1 and 100 seconds"}
    end
  end

  def call("submit_result", args, %{run_id: run_id}) when is_binary(run_id) do
    summary = value(args, :summary)
    artifacts = value(args, :artifacts) || []

    if byte_size(summary) in 1..2_000 and length(artifacts) <= 20 and
         Enum.all?(artifacts, &(byte_size(&1) <= 500)) do
      with {:ok, run} <- Runs.submit_result(run_id, summary, artifacts),
           do: {:ok, %{run: run.id, status: run.status}}
    else
      {:error, "summary or artifacts are invalid or too long"}
    end
  end

  def call(name, _args, _caller)
      when name in ~w(ask_human request_approval wait_for_answer submit_result),
      do: {:error, "no run for this pane"}

  def call("notify_human", args, caller) do
    title = value(args, :title)
    body = value(args, :body)

    if byte_size(title) <= 256 and (is_nil(body) or byte_size(body) <= 2_048) do
      params = %{
        title: title,
        body: body,
        sound: if(value(args, :sound), do: "request", else: "none")
      }

      action_result(Actions.call(:attention, "notification.show", params, caller: caller.pane))
    else
      {:error, "notification is too long"}
    end
  end

  def call("read_agent", args, _caller) do
    agent = value(args, :agent)
    lines = value(args, :lines) || 80

    if is_binary(agent) and byte_size(agent) in 1..256 and is_integer(lines) and lines in 1..200 do
      server = Application.get_env(:jarvis2, :herdr_socket, Socket)
      action_result(Client.read_agent(agent, server: server, lines: lines))
    else
      {:error, "agent or line count is invalid"}
    end
  end

  def call("prompt_agent", args, caller) do
    server = Application.get_env(:jarvis2, :herdr_socket, Socket)
    wait = value(args, :wait) || false

    case Fleet.prompt(caller, value(args, :agent), value(args, :text), wait, server: server) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{code: code}} when code in ["timeout", "disconnected", "agent_prompt_stalled"] ->
        {:error, "prompt may have been submitted; inspect the agent before retrying (#{code})"}

      {:error, %{code: code}} ->
        {:error, "prompt rejected: #{code}"}
    end
  end

  def call("spawn_agent", args, caller) do
    Fleet.spawn_agent(caller, %{
      name: value(args, :name),
      kind: value(args, :kind),
      cwd: value(args, :cwd),
      prompt: value(args, :prompt)
    })
  end

  def call("run_command", args, caller), do: call("run_command", args, caller, fn _, _ -> :ok end)

  def call("wait_for_event", args, _caller),
    do: EventWait.wait(value(args, :match), value(args, :timeout_s))

  def call("apply_layout", args, caller),
    do: Fleet.apply_layout(value(args, :name), caller)

  def call("run_mix", args, caller),
    do: Runs.run_mix(value(args, :task), value(args, :project), parent_run_id: caller[:run_id])

  def call("run_command", args, caller, progress) do
    Fleet.run_command(
      caller,
      %{
        command: value(args, :command),
        wait_for: value(args, :wait_for),
        timeout_s: value(args, :timeout_s)
      },
      progress: progress
    )
  end

  def call(name, args, caller, _progress), do: call(name, args, caller)

  def resource("jarvis2://blackboard"), do: Jarvis2.Blackboard.list()
  def resource("jarvis2://events/recent"), do: journal(:herdr)
  def resource("jarvis2://journal"), do: journal(:mcp)
  def resource("jarvis2://session"), do: view()

  def resource("jarvis2://layout") do
    case view() do
      %{snapshot: snapshot} = mirror when is_map(snapshot) ->
        layout = layout_for(mirror, nil)

        %{
          layout: layout,
          tree: render_tree(layout),
          layout_diff: Map.get(mirror, :layout_diff),
          stale: mirror.stale
        }

      mirror ->
        %{layout: nil, tree: "", layout_diff: Map.get(mirror, :layout_diff), stale: mirror.stale}
    end
  end

  def resource("jarvis2://worktrees") do
    mirror = view()
    %{worktrees: mirror.worktrees, errors: mirror.worktree_errors, stale: mirror.stale}
  end

  defp journal(source),
    do: [source: source] |> Jarvis2.Journal.recent() |> Enum.map(&Jarvis2.Journal.to_map/1)

  defp view, do: Mirror.get(Application.get_env(:jarvis2, :mirror, Mirror))

  defp fresh_view do
    case view() do
      %{stale: false, snapshot: snapshot} = view when is_map(snapshot) -> {:ok, view}
      _ -> {:error, "Herdr mirror is unavailable or stale"}
    end
  end

  defp ask(run_id, kind, attrs) do
    case Questions.ask(run_id, Map.put(attrs, :kind, kind)) do
      {:ok, question} ->
        {:ok, ticket_status(question)}

      {:error, :too_many} ->
        {:error, "too many open questions; wait for answers first"}

      {:error, %Ecto.Changeset{}} ->
        {:error, "invalid question: check the text and options"}
    end
  end

  defp ticket_status(question) do
    base = %{ticket: question.id, status: Atom.to_string(question.status)}
    if question.status == :answered, do: Map.put(base, :answer, question.answer), else: base
  end

  defp value(args, key), do: Map.get(args, key, Map.get(args, Atom.to_string(key)))
  defp valid_key?(key), do: is_binary(key) and byte_size(key) in 1..256
  defp action_result({:ok, result}), do: {:ok, result}
  defp action_result({:error, %{code: code}}), do: {:error, "Herdr request failed: #{code}"}

  defp redact(message) do
    message
    |> String.replace(~r/(?i)bearer\s+\S+/, "Bearer [redacted]")
    |> String.replace(
      ~r/(?i)\b(token|secret|password|api[_-]?key)\s*[=:]\s*\S+/,
      "\\1=[redacted]"
    )
    |> String.replace(~r/[\r\n\x00-\x1f]/, " ")
  end

  defp layout_for(view, workspace) do
    snapshot = view.snapshot

    selected =
      if workspace,
        do: Enum.filter(snapshot["workspaces"], &(&1["workspace_id"] == workspace)),
        else: snapshot["workspaces"]

    ids = MapSet.new(Enum.map(selected, & &1["workspace_id"]))
    tabs = Enum.filter(snapshot["tabs"], &MapSet.member?(ids, &1["workspace_id"]))
    tab_ids = MapSet.new(Enum.map(tabs, & &1["tab_id"]))

    %{
      workspaces: selected,
      tabs: tabs,
      panes: Enum.filter(snapshot["panes"], &MapSet.member?(ids, &1["workspace_id"])),
      agents: Enum.filter(snapshot["agents"], &MapSet.member?(ids, &1["workspace_id"])),
      layouts: Enum.filter(snapshot["layouts"], &MapSet.member?(tab_ids, &1["tab_id"])),
      focused_workspace_id: snapshot["focused_workspace_id"],
      focused_tab_id: snapshot["focused_tab_id"],
      focused_pane_id: snapshot["focused_pane_id"],
      worktrees: view.worktrees,
      worktree_errors: view.worktree_errors
    }
  end

  defp render_tree(layout) do
    tree =
      Enum.map_join(layout.workspaces, "\n", fn workspace ->
        id = workspace["workspace_id"]
        tabs = Enum.filter(layout.tabs, &(&1["workspace_id"] == id))

        children =
          Enum.map_join(tabs, "\n", fn tab ->
            tab_id = tab["tab_id"]
            geometry = Enum.find(layout.layouts, &(&1["tab_id"] == tab_id)) || %{}
            panes = Enum.filter(layout.panes, &(&1["tab_id"] == tab_id))

            "  tab #{tab_id} #{inspect(tab["label"])} layout=#{Jason.encode!(geometry)}\n" <>
              Enum.map_join(panes, "\n", fn pane ->
                agent = Enum.find(layout.agents, &(&1["pane_id"] == pane["pane_id"]))

                "    pane #{pane["pane_id"]} #{inspect(pane["title"] || pane["label"])} agent=#{Jason.encode!(agent)}"
              end)
          end)

        "workspace #{id} #{inspect(workspace["label"])} worktree=#{Jason.encode!(workspace["worktree"])}\n" <>
          children
      end)

    tree <> "\nworktrees=#{Jason.encode!(layout.worktrees)}"
  end
end
