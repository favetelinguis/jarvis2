defmodule Jarvis2.HerdrActionsTest do
  use ExUnit.Case, async: false

  setup do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "sock-#{System.unique_integer([:positive])}"
      )

    parent = self()

    handler = fn request ->
      send(parent, {:request, request})

      case request["method"] do
        "session.snapshot" ->
          {:reply, %{result: %{type: "session_snapshot", snapshot: %{panes: []}}}}

        "agent.read" ->
          {:reply, %{error: %{code: "agent_not_found", message: "not found"}}}

        "agent.list" ->
          :close

        "notification.show" ->
          {:reply, %{result: %{type: "ok"}}}

        "test.delay" ->
          {:later, request["params"]["delay"], %{result: request["params"]["value"]}}

        "test.large" ->
          {:reply, %{result: %{value: String.duplicate("x", 32_768)}}}

        "test.oversized" ->
          {:reply, %{result: %{value: String.duplicate("x", 2_097_152)}}}
      end
    end

    {:ok, _fake, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Jarvis2.Herdr.Socket, [path: path, name: nil]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    %{socket: socket}
  end

  test "disabled scenarios refuse mutations; enabled scenarios execute", %{socket: socket} do
    previous_scenarios = Application.get_env(:jarvis2, :live_scenarios, [])

    on_exit(fn ->
      Application.put_env(:jarvis2, :live_scenarios, previous_scenarios)
    end)

    Application.put_env(:jarvis2, :live_scenarios, [:attention])

    assert {:error, %{code: "disabled"}} =
             Jarvis2.Herdr.Actions.call(:other, "notification.show", %{}, server: socket)

    refute_receive {:request, _}, 50

    assert {:ok, %{"type" => "ok"}} =
             Jarvis2.Herdr.Actions.call(:attention, "notification.show", %{"title" => "hi"},
               server: socket
             )

    assert_receive {:request, %{"method" => "notification.show"}}

    for method <-
          ~w(agent.prompt agent.start agent.send_keys pane.run pane.send_input pane.send_text pane.send_keys) do
      assert {:error, %{code: "guard_unavailable"}} =
               Jarvis2.Herdr.Actions.call(:attention, method, %{}, server: socket)
    end

    refute_receive {:request, _}, 50
  end
end
