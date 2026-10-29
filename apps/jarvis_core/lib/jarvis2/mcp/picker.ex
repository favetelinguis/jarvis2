defmodule Jarvis2.MCP.Picker do
  @moduledoc "Bounded, one-shot requests for the authenticated human picker."
  use GenServer
  require Logger
  alias Jarvis2.Herdr.{Actions, Socket}
  alias Jarvis2.MCP.Identity

  @max_pending 8
  @plugin_id "favetelinguis.jarvis2"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # `agent: false` serves human-invoked actions, whose pane need not host an agent.
  def ask(question, choices, timeout, caller, opts \\ []) do
    require_agent = Keyword.get(opts, :agent, true)

    verified =
      Identity.resolve(%{
        "x-herdr-pane" => caller[:pane],
        "x-herdr-workspace" => caller[:workspace]
      })

    if verified.pane != "unknown" and verified.pane == caller[:pane] and
         verified.workspace == caller[:workspace] and verified.agent_kind == caller[:agent_kind] and
         verified.agent_name == caller[:agent_name] and
         (not require_agent or is_binary(verified.agent_kind)) do
      with {:ok, id} <- GenServer.call(__MODULE__, {:create, question, choices, timeout}),
           :ok <- open(id, verified) do
        GenServer.call(__MODULE__, {:await, id}, timeout * 1_000 + 6_000)
      end
    else
      {:error, "caller pane is unavailable or stale"}
    end
  catch
    :exit, _ -> {:error, "human picker is unavailable"}
  end

  def fetch(id), do: GenServer.call(__MODULE__, {:fetch, id})
  def answer(id, value), do: GenServer.call(__MODULE__, {:answer, id, value})

  defp open(id, caller) do
    env = %{
      "JARVIS2_PICKER_ID" => id,
      "JARVIS2_PICKER_PORT" => to_string(Application.get_env(:jarvis2, :port, 4747)),
      "JARVIS2_PICKER_TOKEN_FILE" =>
        Path.join(Application.fetch_env!(:jarvis2, :state_dir), "token")
    }

    params = %{
      plugin_id: @plugin_id,
      entrypoint: "picker",
      placement: "popup",
      focus: true,
      env: env
    }

    socket = Application.get_env(:jarvis2, :herdr_socket, Socket)

    case Actions.call(:human_picker, "plugin.pane.open", params,
           caller: caller.pane,
           server: socket,
           timeout: 5_000
         ) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning("Herdr human picker open failed code=#{inspect(error[:code])}")
        GenServer.cast(__MODULE__, {:discard, id})
        {:error, "could not open human picker; inspect the workspace before retrying"}
    end
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:create, question, choices, timeout}, {owner, _}, state) do
    if map_size(state) < @max_pending do
      id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      entry = %{
        question: question,
        choices: choices,
        owner: owner,
        monitor: Process.monitor(owner),
        timer: Process.send_after(self(), {:expire, id}, timeout * 1_000),
        waiter: nil,
        result: nil
      }

      {:reply, {:ok, id}, Map.put(state, id, entry)}
    else
      {:reply, {:error, "human picker is busy"}, state}
    end
  end

  def handle_call({:await, id}, from, state) do
    case state[id] do
      %{result: nil, waiter: nil} = entry ->
        {:noreply, Map.put(state, id, %{entry | waiter: from})}

      %{result: result} when not is_nil(result) ->
        {:reply, result, drop(state, id)}

      _ ->
        {:reply, {:error, "human picker request expired"}, state}
    end
  end

  def handle_call({:fetch, id}, _from, state) do
    case state[id] do
      %{result: nil} = entry ->
        {:reply, {:ok, %{question: entry.question, choices: entry.choices}}, state}

      _ ->
        {:reply, :error, state}
    end
  end

  def handle_call({:answer, id, answer}, _from, state) do
    case state[id] do
      %{result: nil} = entry ->
        case resolve_answer(answer, entry.choices) do
          {:ok, value} ->
            result = {:ok, %{answer: value, dry_run: false}}

            if entry.waiter do
              GenServer.reply(entry.waiter, result)
              {:reply, :ok, drop(state, id)}
            else
              {:reply, :ok, Map.put(state, id, %{entry | result: result})}
            end

          :error ->
            {:reply, :error, state}
        end

      _ ->
        {:reply, :error, state}
    end
  end

  @impl true
  def handle_cast({:discard, id}, state), do: {:noreply, drop(state, id)}

  @impl true
  def handle_info({:expire, id}, state) do
    if entry = state[id] do
      if entry.waiter, do: GenServer.reply(entry.waiter, {:error, "human picker timed out"})
    end

    {:noreply, drop(state, id)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    id = Enum.find_value(state, fn {id, entry} -> if entry.monitor == ref, do: id end)
    {:noreply, if(id, do: drop(state, id), else: state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp drop(state, id) do
    case Map.pop(state, id) do
      {nil, state} ->
        state

      {entry, state} ->
        Process.cancel_timer(entry.timer)
        Process.demonitor(entry.monitor, [:flush])
        state
    end
  end

  defp resolve_answer(%{"cancel" => true}, _), do: {:ok, nil}

  defp resolve_answer(%{"index" => index}, choices) when is_integer(index) and index >= 0 do
    case Enum.fetch(choices, index) do
      {:ok, choice} -> {:ok, choice}
      :error -> :error
    end
  end

  defp resolve_answer(%{"text" => text}, []) when is_binary(text) and byte_size(text) <= 256 do
    if String.valid?(text) and not String.match?(text, ~r/[\p{C}]/u),
      do: {:ok, text},
      else: :error
  end

  defp resolve_answer(_, _), do: :error
end
