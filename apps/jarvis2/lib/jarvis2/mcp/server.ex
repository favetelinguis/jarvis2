defmodule Jarvis2.MCP.Server do
  @moduledoc false
  use Anubis.Server, name: "jarvis2", version: "0.1.0", capabilities: [:tools, :resources]
  alias Anubis.Server.{Frame, Handlers, Response}
  alias Jarvis2.MCP.{Caller, Tools}
  require Logger

  @tools [
    {"whoami", "Resolve your Herdr pane identity.", %{}},
    {"log", "Write a message to the Jarvis2 log; fields are not logged.",
     %{
       level: {:required, {:enum, ["debug", "info", "warning", "error"]}},
       message: {:required, :string},
       fields: :map
     }},
    {"blackboard_put", "Store a JSON value for other agents.",
     %{key: {:required, :string}, value: :any}},
    {"blackboard_get", "Read a blackboard value.", %{key: {:required, :string}}},
    {"blackboard_list", "List blackboard values.", %{}},
    {"list_agents", "List agents in the session mirror.", %{workspace: :string}},
    {"get_layout", "Inspect the current session layout.",
     %{workspace: :string, format: {:enum, ["tree", "json"]}}},
    {"list_worktrees", "List discovered worktrees per repository.", %{repo: :string}},
    {"notify_human", "Send a notification through Herdr.",
     %{title: {:required, :string}, body: :string, sound: :boolean}},
    {"read_agent", "Read recent output from a Herdr agent.",
     %{agent: {:required, :string}, lines: :integer}},
    {"prompt_agent", "Prompt a ready agent in your workspace; guarded.",
     %{agent: {:required, :string}, text: {:required, :string}, wait: :boolean}},
    {"spawn_agent", "Create a sibling agent in the caller's cwd; guarded.",
     %{name: {:required, :string}, kind: {:required, :string}, cwd: :string, prompt: :string}},
    {"run_command", "Run a shell command in a new sibling pane; guarded and not sandboxed.",
     %{command: {:required, :string}, wait_for: :string, timeout_s: :integer}},
    {"wait_for_event",
     "Wait for a future Herdr event. Match is an object with type and optional scalar filters.",
     %{match: {:required, :map}, timeout_s: {:required, :integer}}},
    {"run_mix",
     "Run an allow-listed Mix task in the configured trusted project; this executes project code.",
     %{
       task: {:required, {:enum, ["test", "format --check-formatted", "compile"]}},
       project: :string
     }},
    {"apply_layout", "Create a new developer tab in your workspace.",
     %{name: {:required, {:enum, ["dev"]}}}},
    {"ask_human",
     "Ask the human a question; returns a ticket. Poll wait_for_answer until it is no longer pending.",
     %{prompt: {:required, :string}, options: {:list, :string}}},
    {"request_approval",
     "Ask the human to approve or deny an action before you take it; returns a ticket for wait_for_answer.",
     %{action: {:required, :string}, detail: :string}},
    {"wait_for_answer",
     "Wait up to timeout_s seconds (default 30, max 100) for a ticket's answer.",
     %{ticket: {:required, :string}, timeout_s: :integer}},
    {"submit_result", "Finish your run with a summary and optional artifact paths or URLs.",
     %{summary: {:required, :string}, artifacts: {:list, :string}}}
  ]
  @resources ~w(jarvis2://session jarvis2://layout jarvis2://worktrees jarvis2://events/recent jarvis2://journal jarvis2://blackboard)

  @impl true
  def init(_client, frame) do
    frame =
      Enum.reduce(@tools, frame, fn {name, description, schema}, acc ->
        Frame.register_tool(acc, name,
          description: description,
          input_schema: schema,
          annotations: %{}
        )
      end)

    # Peri treats a required null as missing; MCP requires the key but permits JSON null.
    frame =
      update_in(frame.tools["blackboard_put"].input_schema["required"], fn required ->
        Enum.uniq(["value" | required || []])
      end)

    frame =
      Enum.reduce(@resources, frame, fn uri, acc ->
        Frame.register_resource(acc, uri, name: uri, mime_type: "application/json")
      end)

    {:ok, frame}
  end

  @impl true
  def handle_request(%{"method" => "tools/call"} = request, frame) do
    caller = Caller.resolve(frame.context.headers)
    frame = Frame.assign(frame, :jarvis2_caller, caller)
    result = dispatch_tool_request(request, frame)

    name =
      case request do
        %{"params" => %{"name" => name}} when is_binary(name) -> String.slice(name, 0, 128)
        _ -> "unknown"
      end

    outcome = outcome(result)

    args =
      case request do
        %{"params" => %{"arguments" => args}} when is_map(args) -> args
        _ -> %{}
      end

    Jarvis2.Journal.record(%{
      source: :mcp,
      run_id: caller[:run_id],
      type: "tool." <> name,
      outcome: String.to_existing_atom(outcome),
      payload: %{caller: caller, args: args}
    })

    entry = %{tool: name, caller: caller, outcome: outcome}

    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "mcp:tool_call",
      {:jarvis2, "mcp:tool_call", entry}
    )

    Logger.info("MCP tool=#{inspect(name)} pane=#{inspect(caller.pane)} outcome=#{outcome}")
    result
  end

  def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

  defp outcome({:reply, %{"isError" => true, "content" => [%{"text" => text} | _]}, _})
       when text in [
              "request rejected: disabled",
              "prompt rejected: disabled",
              "Herdr request failed: disabled"
            ],
       do: "refused"

  defp outcome({:reply, %{"isError" => true}, _}), do: "error"
  defp outcome({:reply, _, _}), do: "ok"
  defp outcome(_), do: "error"

  defp dispatch_tool_request(
         %{"params" => %{"name" => "blackboard_put", "arguments" => args}} = request,
         frame
       )
       when is_map(args) do
    if Map.has_key?(args, "value") do
      Handlers.handle(request, __MODULE__, frame)
    else
      {:error, Anubis.MCP.Error.protocol(:invalid_params, %{message: "value is required"}), frame}
    end
  end

  defp dispatch_tool_request(%{"params" => %{"name" => "blackboard_put"}}, frame),
    do:
      {:error, Anubis.MCP.Error.protocol(:invalid_params, %{message: "value is required"}), frame}

  defp dispatch_tool_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

  @impl true
  def handle_tool_call(name, args, frame) do
    caller = frame.assigns[:jarvis2_caller] || Caller.resolve(frame.context.headers)

    progress = fn step, message ->
      if token = Frame.progress_token(frame) do
        try do
          Anubis.Server.Notifier.progress(frame, token, step, total: 2, message: message)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end
    end

    response =
      try do
        case call_tool(name, args, caller, progress) do
          {:ok, value} ->
            Response.json(Response.tool(), value)

          {:error, %{code: code}} when is_binary(code) ->
            Response.error(Response.tool(), "request rejected: #{code}")

          {:error, message} ->
            Response.error(Response.tool(), message)
        end
      rescue
        _ -> Response.error(Response.tool(), "tool execution failed")
      end

    {:reply, response, frame}
  end

  defp call_tool(name, args, caller, progress), do: Tools.call(name, args, caller, progress)

  @impl true
  def handle_resource_read(uri, frame) do
    data = Tools.resource(uri)
    {:reply, Response.json(Response.resource(), data), frame}
  end
end
