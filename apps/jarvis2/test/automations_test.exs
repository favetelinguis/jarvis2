defmodule Jarvis2.AutomationsTest do
  use Jarvis2.DataCase, async: false

  alias Jarvis2.Herdr.Socket
  alias Jarvis2.Automations.{Attention, OutputWatcher}

  setup do
    previous_scenarios = Application.get_env(:jarvis2, :live_scenarios, [])
    Application.put_env(:jarvis2, :live_scenarios, [])

    on_exit(fn ->
      Application.put_env(:jarvis2, :live_scenarios, previous_scenarios)
    end)

    :ok
  end

  test "disabled output watcher refuses the notification without exposing its contents" do
    start_supervised!({OutputWatcher, [name: nil]})
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "scenario:output_watcher")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Phoenix.PubSub.local_broadcast(
          Jarvis2.PubSub,
          "herdr:pane.output_matched",
          {:jarvis2, "herdr:pane.output_matched",
           %{
             type: "pane.output_matched",
             data: %{"pane_id" => "w1:p1", "matched_line" => "FAIL token=private-value"}
           }}
        )

        assert_receive {:jarvis2, "scenario:output_watcher", %{pane: "w1:p1", outcome: :refused}},
                       1_000
      end)

    assert log =~ "pane=\"w1:p1\""
    refute log =~ "private-value"

    assert [%{type: "automation.output_watcher", outcome: :refused, payload: payload}] =
             Jarvis2.Journal.recent(source: :automation)

    assert payload == %{"pane" => "w1:p1"}
    refute inspect(Jarvis2.Journal.recent()) =~ "private-value"
  end

  test "attention notifies once for a transition and clears on focus" do
    start_supervised!({Attention, [name: nil]})
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "scenario:attention")

    status = %{
      type: "pane.agent_status_changed",
      data: %{"pane_id" => "w1:p1", "agent_status" => "blocked", "agent" => "pi"}
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Phoenix.PubSub.local_broadcast(
          Jarvis2.PubSub,
          "herdr:pane.agent_status_changed",
          {:jarvis2, "herdr:pane.agent_status_changed", status}
        )

        assert_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "blocked"}}, 1_000

        Phoenix.PubSub.local_broadcast(
          Jarvis2.PubSub,
          "herdr:pane.agent_status_changed",
          {:jarvis2, "herdr:pane.agent_status_changed", status}
        )

        refute_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "blocked"}}, 50

        Phoenix.PubSub.local_broadcast(
          Jarvis2.PubSub,
          "herdr:pane.focused",
          {:jarvis2, "herdr:pane.focused",
           %{
             type: "pane.focused",
             data: %{"pane_id" => "w1:p1"}
           }}
        )

        assert_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "cleared"}}, 1_000
      end)

    assert log =~ "Herdr attention"

    # One notification for the transition, none for the repeat.
    assert [
             %{
               type: "automation.attention",
               outcome: :refused,
               payload: %{"pane" => "w1:p1", "state" => "blocked"}
             }
           ] =
             Jarvis2.Journal.recent(source: :automation)
  end

  test "explicitly enabled scenarios send only expected live requests" do
    path =
      Path.join(
        Application.fetch_env!(:jarvis2, :state_dir),
        "scenario-#{System.unique_integer([:positive])}"
      )

    parent = self()

    handler = fn request ->
      send(parent, {:herdr_write, request})
      {:reply, %{result: %{type: "ok"}}}
    end

    {:ok, _fake, listener} = Jarvis2.Test.FakeHerdr.start_link(path, handler)
    {:ok, socket} = start_supervised({Socket, [path: path, name: nil]})

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    Application.put_env(:jarvis2, :live_scenarios, [:attention, :output_watcher])
    start_supervised!({Attention, [name: nil, socket: socket]})
    start_supervised!({OutputWatcher, [name: nil, socket: socket]})
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "scenario:attention")
    Phoenix.PubSub.subscribe(Jarvis2.PubSub, "scenario:output_watcher")

    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "herdr:pane.agent_status_changed",
      {:jarvis2, "herdr:pane.agent_status_changed",
       %{
         type: "pane.agent_status_changed",
         data: %{"pane_id" => "w1:p1", "agent_status" => "blocked"}
       }}
    )

    assert_receive {:herdr_write,
                    %{"method" => "notification.show", "params" => %{"sound" => "request"}}},
                   1_000

    assert_receive {:herdr_write, %{"method" => "client.window_title.set"}}, 1_000
    assert_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "blocked"}}, 1_000

    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "herdr:pane.focused",
      {:jarvis2, "herdr:pane.focused",
       %{
         type: "pane.focused",
         data: %{"pane_id" => "w1:p2"}
       }}
    )

    refute_receive {:herdr_write, _}, 50

    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "herdr:pane.focused",
      {:jarvis2, "herdr:pane.focused",
       %{
         type: "pane.focused",
         data: %{"pane_id" => "w1:p1"}
       }}
    )

    assert_receive {:herdr_write, %{"method" => "client.window_title.clear"}}, 1_000
    assert_receive {:jarvis2, "scenario:attention", %{pane: "w1:p1", state: "cleared"}}, 1_000

    Phoenix.PubSub.local_broadcast(
      Jarvis2.PubSub,
      "herdr:pane.output_matched",
      {:jarvis2, "herdr:pane.output_matched",
       %{
         type: "pane.output_matched",
         data: %{"pane_id" => "w1:p1", "matched_line" => "FAIL test"}
       }}
    )

    assert_receive {:herdr_write,
                    %{"method" => "notification.show", "params" => %{"body" => "FAIL test"}}},
                   1_000

    assert_receive {:jarvis2, "scenario:output_watcher", %{pane: "w1:p1", outcome: :ok}}, 1_000
  end
end
