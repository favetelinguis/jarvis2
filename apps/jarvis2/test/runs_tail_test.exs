defmodule Jarvis2.Runs.TailTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.Runs
  alias Jarvis2.Runs.{Run, Tail}

  defmodule Mirror do
    use GenServer
    def start_link(view), do: GenServer.start_link(__MODULE__, view)
    def init(view), do: {:ok, view}
    def handle_call(:get, _from, view), do: {:reply, view, view}
    def handle_call({:put, view}, _from, _), do: {:reply, :ok, view}
  end

  setup do
    pane = %{
      "pane_id" => "w1:p9",
      "terminal_id" => "term-run",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1"
    }

    view = %{
      stale: false,
      snapshot: %{"panes" => [pane], "agents" => [Map.put(pane, "agent", "pi")]}
    }

    mirror = start_supervised!({Mirror, view})
    {:ok, text} = Agent.start_link(fn -> "first output" end)

    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "tail-#{System.unique_integer([:positive])}"
      )

    {:ok, _, listener} =
      Jarvis2.Test.FakeHerdr.start_link(path, fn %{"method" => "pane.read"} ->
        read = %{pane_id: "w1:p9", text: Agent.get(text, & &1)}
        {:reply, %{result: %{type: "pane_read", read: read}}}
      end)

    socket = start_supervised!({Jarvis2.Herdr.Socket, [name: nil, path: path]})
    on_exit(fn -> :gen_tcp.close(listener) end)

    for {key, value} <- [mirror: mirror, herdr_socket: socket] do
      old = Application.fetch_env(:jarvis2, key)
      Application.put_env(:jarvis2, key, value)

      on_exit(fn ->
        case old do
          {:ok, v} -> Application.put_env(:jarvis2, key, v)
          :error -> Application.delete_env(:jarvis2, key)
        end
      end)
    end

    {:ok, run} = Runs.create_run(%{name: "tail", task: "t", cwd: File.cwd!()})

    {:ok, run} =
      run
      |> Run.progress_changeset(%{status: :working, pane_id: "w1:p9", terminal_id: "term-run"})
      |> Repo.update()

    %{run: run, text: text}
  end

  test "reads the pane for a watcher, broadcasts changes and stops with the last watcher", ctx do
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, Tail.topic(ctx.run.id))

    watcher =
      spawn(fn ->
        Tail.watch(ctx.run.id)
        Process.sleep(:infinity)
      end)

    assert_receive {:tail, "first output"}, 2_000

    [{pid, _}] = Registry.lookup(Jarvis2.Runs.TailRegistry, ctx.run.id)
    ref = Process.monitor(pid)

    Agent.update(ctx.text, fn _ -> "second output" end)
    assert_receive {:tail, "second output"}, 3_000

    # A second watcher shares the process and immediately gets the latest text.
    assert Tail.watch(ctx.run.id) == "second output"

    # The test process is still watching, so losing the first watcher keeps the tail alive.
    Process.exit(watcher, :kill)
    refute_receive {:DOWN, ^ref, _, _, _}, 200
    assert Process.alive?(pid)
  end

  test "stops once nobody watches", ctx do
    watcher =
      spawn(fn ->
        Tail.watch(ctx.run.id)
        Process.sleep(:infinity)
      end)

    Process.sleep(100)
    [{pid, _}] = Registry.lookup(Jarvis2.Runs.TailRegistry, ctx.run.id)
    ref = Process.monitor(pid)
    Process.exit(watcher, :kill)
    assert_receive {:DOWN, ^ref, _, _, :normal}, 1_000
  end
end
