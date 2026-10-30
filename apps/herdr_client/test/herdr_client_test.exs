defmodule Jarvis2.HerdrClientTest do
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

  test "requires an explicit socket path even when a Herdr environment is present" do
    previous = System.get_env("HERDR_SOCKET_PATH")
    System.put_env("HERDR_SOCKET_PATH", "/not-the-owned-session")

    on_exit(fn ->
      if previous,
        do: System.put_env("HERDR_SOCKET_PATH", previous),
        else: System.delete_env("HERDR_SOCKET_PATH")
    end)

    assert_raise KeyError, fn -> Jarvis2.Herdr.Socket.init([]) end
  end

  test "reads and server error envelopes pass through the client", %{socket: socket} do
    assert {:ok, %{"snapshot" => %{"panes" => []}}} =
             Jarvis2.Herdr.Client.snapshot(server: socket)

    assert_receive {:request, %{"method" => "session.snapshot"}}

    assert {:error, %{code: "agent_not_found", message: "not found"}} =
             Jarvis2.Herdr.Client.read_agent("missing", server: socket)
  end

  test "a dropped connection fails the request and the next call reconnects", %{socket: socket} do
    assert {:error, %{code: "disconnected"}} = Jarvis2.Herdr.Client.list_agents(server: socket)
    assert {:ok, _} = Jarvis2.Herdr.Client.snapshot(server: socket)
  end

  test "correlates out-of-order responses and ignores responses after a deadline", %{
    socket: socket
  } do
    slow =
      Task.async(fn ->
        Jarvis2.Herdr.Socket.request("test.delay", %{delay: 100, value: "slow"}, server: socket)
      end)

    assert_receive {:request, %{"method" => "test.delay"}}

    fast =
      Task.async(fn ->
        Jarvis2.Herdr.Socket.request("test.delay", %{delay: 0, value: "fast"}, server: socket)
      end)

    assert {:ok, "fast"} = Task.await(fast)
    assert {:ok, "slow"} = Task.await(slow)

    assert {:error, %{code: "timeout"}} =
             Jarvis2.Herdr.Socket.request("test.delay", %{delay: 100, value: "late"},
               server: socket,
               timeout: 20
             )

    Process.sleep(120)
    assert {:ok, _} = Jarvis2.Herdr.Client.snapshot(server: socket)
  end

  test "reads responses larger than the default line buffer", %{socket: socket} do
    assert {:ok, %{"value" => value}} =
             Jarvis2.Herdr.Socket.request("test.large", %{}, server: socket)

    assert byte_size(value) == 32_768
  end

  test "rejects responses above the packet limit and reconnects", %{socket: socket} do
    assert {:error, %{code: "disconnected"}} =
             Jarvis2.Herdr.Socket.request("test.oversized", %{}, server: socket)

    assert {:ok, _} = Jarvis2.Herdr.Client.snapshot(server: socket)
  end

  test "rejects oversized encoded requests before sending", %{socket: socket} do
    text = String.duplicate("\"", 530_000)
    assert byte_size(text) < 1_048_576

    assert {:error, %{code: "invalid_request"}} =
             Jarvis2.Herdr.Socket.request("notification.show", %{text: text}, server: socket)

    refute_receive {:request, _}, 100
    assert {:ok, _} = Jarvis2.Herdr.Client.snapshot(server: socket)
  end

  test "invalid request values return errors without crashing the connection", %{socket: socket} do
    assert {:error, %{code: "invalid_request"}} =
             Jarvis2.Herdr.Socket.request("test.delay", %{pid: self()}, server: socket)

    assert {:error, %{code: "invalid_request"}} =
             Jarvis2.Herdr.Socket.request("test.delay", %{}, server: socket, timeout: 0)

    assert {:ok, _} = Jarvis2.Herdr.Client.snapshot(server: socket)
  end
end
