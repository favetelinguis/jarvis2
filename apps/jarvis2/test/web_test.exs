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

  test "removed endpoints return not found", %{port: port, token: token} do
    headers = [{"authorization", "Bearer " <> token}]
    assert {404, _} = request(port, :post, "/hook/action/x", "{}", headers)
    assert {404, _} = request(port, :get, "/picker/x", "", headers)
    assert {404, _} = request(port, :post, "/picker/x", "{}", headers)
    assert {404, _} = request(port, :get, "/dashboard", "", headers)
    assert {406, _} = request(port, :post, "/mcp", "{}", headers)
  end

  test "protected routes reject missing, wrong and duplicate credentials", %{
    port: port,
    token: token
  } do
    for path <- ["/mcp"] do
      assert {401, _} = request(port, :post, path, "{}")
      assert {401, _} = request(port, :post, path, "{}", [{"authorization", "Bearer wrong"}])

      assert {401, _} =
               request(port, :post, path, "{}", [
                 {"authorization", "Bearer " <> token},
                 {"authorization", "Bearer " <> token}
               ])
    end
  end

  test "status script reads the live HTTP endpoint", %{port: port} do
    assert {status, 0} =
             System.cmd(Path.expand("../../../bin/status", __DIR__), [],
               env: [{"JARVIS2_PORT", Integer.to_string(port)}],
               stderr_to_stdout: true
             )

    assert status =~ "◆"
  end

  test "status script reports when the server is unavailable" do
    assert {output, code} =
             System.cmd(Path.expand("../../../bin/status", __DIR__), [],
               env: [{"JARVIS2_PORT", "1"}],
               stderr_to_stdout: true
             )

    assert code != 0
    assert output =~ "start with mix run --no-halt"
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
