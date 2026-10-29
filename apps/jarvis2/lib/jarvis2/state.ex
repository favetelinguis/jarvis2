defmodule Jarvis2.State do
  @moduledoc "In-memory blackboard and bounded event and MCP journals."
  use GenServer

  @limit 200
  @blackboard_limit 256

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, if(name, do: [name: name], else: []))
  end

  def put(key, value, server \\ __MODULE__), do: GenServer.call(server, {:put, key, value})
  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def list, do: GenServer.call(__MODULE__, :list)

  def record_event(event, server \\ __MODULE__),
    do: GenServer.call(server, {:record, :events, event})

  def journal(entry, server \\ __MODULE__), do: GenServer.call(server, {:record, :journal, entry})
  def events(server \\ __MODULE__), do: GenServer.call(server, {:recent, :events})
  def recent_journal(server \\ __MODULE__), do: GenServer.call(server, {:recent, :journal})
  def mcp_call_count(server \\ __MODULE__), do: GenServer.call(server, :mcp_call_count)

  @impl true
  def init(:ok) do
    table = :ets.new(:jarvis2_blackboard, [:set, :private])
    {:ok, %{blackboard: table, events: [], journal: [], mcp_call_count: 0}}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) when is_binary(key) do
    if :ets.member(state.blackboard, key) or
         :ets.info(state.blackboard, :size) < @blackboard_limit do
      true = :ets.insert(state.blackboard, {key, value})
      {:reply, :ok, state}
    else
      {:reply, {:error, :full}, state}
    end
  end

  def handle_call({:get, key}, _from, state) do
    result =
      case :ets.lookup(state.blackboard, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :error
      end

    {:reply, result, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, state.blackboard |> :ets.tab2list() |> Map.new(), state}
  end

  def handle_call(:mcp_call_count, _from, state), do: {:reply, state.mcp_call_count, state}
  def handle_call({:recent, name}, _from, state), do: {:reply, Enum.reverse(state[name]), state}

  def handle_call({:record, name, entry}, _from, state) do
    state = Map.update!(state, name, &Enum.take([entry | &1], @limit))
    state = if name == :journal, do: Map.update!(state, :mcp_call_count, &(&1 + 1)), else: state
    {:reply, :ok, state}
  end
end
