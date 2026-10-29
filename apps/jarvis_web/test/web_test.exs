defmodule Jarvis2.WebTest do
  use ExUnit.Case, async: false

  setup_all do
    start_supervised!({Finch, name: Jarvis2.TestFinch})
    {:ok, server} = Bandit.start_link(plug: Jarvis2.Web.Router, ip: {127, 0, 0, 1}, port: 0)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{port: port, token: Jarvis2.Token.get()}
  end

  test "health and status are available on loopback", %{port: port} do
    assert {200, %{"status" => "ok"}} = request(port, :get, "/healthz")
    assert {200, status} = request(port, :get, "/status")
    assert is_binary(status)
  end

  test "dashboard returns bounded summaries and the terminal client renders them", %{
    port: port,
    token: token
  } do
    Jarvis2.State.record_event(%{
      delivery: "socket",
      type: "pane.output_matched",
      data: %{"matched_line" => "dashboard-private-value"}
    })

    Jarvis2.State.journal(%{
      tool: "example_tool",
      caller: %{pane: "w1:p1", cwd: "dashboard-private-value"},
      outcome: "ok",
      timestamp: "now"
    })

    assert {401, _} = request(port, :get, "/dashboard")
    headers = [{"authorization", "Bearer " <> token}]
    assert {200, data} = request(port, :get, "/dashboard", "", headers)
    assert Enum.any?(data["events"], &(&1["type"] == "pane.output_matched"))
    assert Enum.any?(data["journal"], &(&1["tool"] == "example_tool" and &1["pane"] == "w1:p1"))
    refute Jason.encode!(data) =~ "dashboard-private-value"

    assert {403, _} =
             request(port, :get, "/dashboard", "", [{"origin", "https://example.com"} | headers])

    env = [
      {"JARVIS2_PORT", Integer.to_string(port)},
      {"JARVIS2_DASHBOARD_STATE_DIR", Application.fetch_env!(:jarvis2, :state_dir)}
    ]

    assert {output, 0} =
             System.cmd(Path.expand("../../../bin/dashboard", __DIR__), [],
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "Jarvis2 dashboard"
    assert output =~ "pane.output_matched" and output =~ "example_tool"
    refute output =~ "dashboard-private-value"
    refute output =~ token
  end

  test "dashboard runs interactively in a terminal and exits on q", %{port: port} do
    program = """
    import os, pty, select, subprocess, sys, time
    master, slave = pty.openpty()
    proc = subprocess.Popen([sys.argv[1]], stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    data = b''
    deadline = time.monotonic() + 5
    while b'Jarvis2 dashboard' not in data and time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            data += os.read(master, 65536)
    assert b'Jarvis2 dashboard' in data, data
    os.write(master, b'q')
    assert proc.wait(timeout=5) == 0
    os.close(master)
    print('dashboard exited cleanly')
    """

    env = [
      {"JARVIS2_PORT", Integer.to_string(port)},
      {"JARVIS2_DASHBOARD_STATE_DIR", Application.fetch_env!(:jarvis2, :state_dir)}
    ]

    assert {output, 0} =
             System.cmd(
               "/usr/bin/python3",
               ["-c", program, Path.expand("../../../bin/dashboard", __DIR__)],
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "dashboard exited cleanly"
  end

  test "protected routes reject missing, wrong and duplicate credentials", %{
    port: port,
    token: token
  } do
    for path <- ["/hook/action/probe", "/mcp"] do
      assert {401, _} = request(port, :post, path, "{}")
      assert {401, _} = request(port, :post, path, "{}", [{"authorization", "Bearer wrong"}])

      assert {401, _} =
               request(port, :post, path, "{}", [
                 {"authorization", "Bearer " <> token},
                 {"authorization", "Bearer " <> token}
               ])
    end
  end

  test "authenticated hooks publish their JSON body", %{port: port, token: token} do
    Jarvis2.Bus.subscribe("hook:action")
    headers = [{"authorization", "Bearer " <> token}]
    body = ~s({"context":{"pane_id":"w1:p1"}})
    assert {202, _} = request(port, :post, "/hook/action/probe", body, headers)

    assert_receive {:jarvis2, "hook:action",
                    %{id: "probe", body: %{"context" => %{"pane_id" => "w1:p1"}}}}

    assert {400, _} = request(port, :post, "/hook/action/probe", "{", headers)
    assert {400, _} = request(port, :post, "/hook/action/probe", "[]", headers)

    assert {413, _} =
             request(
               port,
               :post,
               "/hook/action/probe",
               Jason.encode!(%{"x" => String.duplicate("a", 70_000)}),
               headers
             )

    assert {406, %{"error" => %{"code" => -32600}}} = request(port, :post, "/mcp", "{}", headers)
  end

  test "plugin forwarder sends action context and link data to the app", %{port: port} do
    Jarvis2.Bus.subscribe("hook:action")

    env = [
      {"JARVIS2_PORT", Integer.to_string(port)},
      {"HERDR_PLUGIN_STATE_DIR", Application.fetch_env!(:jarvis2, :state_dir)},
      {"HERDR_PLUGIN_CONTEXT_JSON", ~s({"workspace_id":"w1","focused_pane_id":"w1:p1"})},
      {"HERDR_PLUGIN_CLICKED_URL", "https://github.com/acme/repo/issues/12"}
    ]

    assert {_, 0} =
             System.cmd(Path.expand("../../../bin/forward", __DIR__), ["action", "issue-link"],
               env: env,
               stderr_to_stdout: true
             )

    assert_receive {:jarvis2, "hook:action",
                    %{
                      id: "issue-link",
                      body: %{
                        "context" => %{"workspace_id" => "w1"},
                        "clicked_url" => "https://github.com/acme/repo/issues/12"
                      }
                    }},
                   1_000
  end

  test "plugin event forwarder preserves the event payload", %{port: port} do
    Jarvis2.Bus.subscribe("hook:event")

    env = [
      {"JARVIS2_PORT", Integer.to_string(port)},
      {"HERDR_PLUGIN_STATE_DIR", Application.fetch_env!(:jarvis2, :state_dir)},
      {"HERDR_PLUGIN_CONTEXT_JSON", "{}"},
      {"HERDR_PLUGIN_EVENT_JSON", ~s({"event":"worktree_created","data":{"workspace_id":"w1"}})}
    ]

    assert {_, 0} =
             System.cmd(
               Path.expand("../../../bin/forward", __DIR__),
               ["event", "worktree.created"],
               env: env,
               stderr_to_stdout: true
             )

    assert_receive {:jarvis2, "hook:event",
                    %{
                      delivery: "hook",
                      id: "worktree.created",
                      body: %{"event" => %{"data" => %{"workspace_id" => "w1"}}}
                    }},
                   1_000
  end

  test "context and link hook logs omit sensitive fields and URL query strings", %{
    port: port,
    token: token
  } do
    headers = [{"authorization", "Bearer " <> token}]

    context =
      Jason.encode!(%{
        context: %{workspace_id: "w1", focused_pane_id: "w1:p1", secret: "private-value"}
      })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {202, _} = request(port, :post, "/hook/action/probe-context", context, headers)
      end)

    assert log =~ "w1:p1"
    refute log =~ "private-value"

    link =
      Jason.encode!(%{clicked_url: "https://github.com/acme/repo/issues/12?token=private-value"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {202, _} = request(port, :post, "/hook/action/issue-link", link, headers)
      end)

    assert log =~ "https://github.com/acme/repo/issues/12"
    refute log =~ "private-value"
  end

  test "forwarder rejects malformed context and fails fast when the app is down", %{port: port} do
    env = [
      {"JARVIS2_PORT", Integer.to_string(port)},
      {"HERDR_PLUGIN_STATE_DIR", Application.fetch_env!(:jarvis2, :state_dir)},
      {"HERDR_PLUGIN_CONTEXT_JSON", "{"}
    ]

    assert {output, code} =
             System.cmd(Path.expand("../../../bin/forward", __DIR__), ["action", "probe-context"],
               env: env,
               stderr_to_stdout: true
             )

    assert code != 0
    assert output =~ "invalid"

    env = [
      {"JARVIS2_PORT", "1"},
      {"HERDR_PLUGIN_STATE_DIR", Application.fetch_env!(:jarvis2, :state_dir)},
      {"HERDR_PLUGIN_CONTEXT_JSON", "{}"}
    ]

    assert {"jarvis2 not running; run action start-server\n", code} =
             System.cmd(Path.expand("../../../bin/forward", __DIR__), ["action", "probe-context"],
               env: env,
               stderr_to_stdout: true
             )

    assert code != 0

    assert {"jarvis2 not running; run action start-server\n", code} =
             System.cmd(Path.expand("../../../bin/status", __DIR__), [],
               env: env,
               stderr_to_stdout: true
             )

    assert code != 0
  end

  test "plugin status reads the live HTTP endpoint", %{port: port} do
    assert {status, 0} =
             System.cmd(Path.expand("../../../bin/status", __DIR__), [],
               env: [{"JARVIS2_PORT", Integer.to_string(port)}],
               stderr_to_stdout: true
             )

    assert status =~ "◆"
  end

  test "token is persistent, private, and not exposed by status", %{token: token, port: port} do
    path = Path.join(Application.fetch_env!(:jarvis2, :state_dir), "token")
    assert File.read!(path) == token <> "\n"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert {200, status} = request(port, :get, "/status")
    refute String.contains?(status, token)
  end

  defp request(port, method, path, body \\ "", headers \\ []) do
    url = "http://127.0.0.1:#{port}#{path}"
    request = Finch.build(method, url, [{"content-type", "application/json"} | headers], body)
    {:ok, response} = Finch.request(request, Jarvis2.TestFinch, receive_timeout: 5_000)

    decoded =
      case Jason.decode(response.body) do
        {:ok, value} -> value
        _ -> response.body
      end

    {response.status, decoded}
  end
end
