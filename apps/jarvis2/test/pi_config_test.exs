defmodule Jarvis2.PiConfigTest do
  use ExUnit.Case, async: false

  test "the run extension registers the run's MCP server independently of the working directory" do
    extension = Path.expand("../../../.pi/jarvis2-run.js", __DIR__)

    script = """
    const fs = require('node:fs');
    const source = fs.readFileSync(process.argv[1], 'utf8');
    import('data:text/javascript;base64,' + Buffer.from(source).toString('base64')).then(({default: register}) => {
      register({registerMcpServer: (name, config) => console.log(JSON.stringify({name, config}))});
    });
    """

    {output, 0} =
      System.cmd("node", ["-e", script, extension],
        cd: System.tmp_dir!(),
        env: [
          {"JARVIS2_MCP_URL", "http://127.0.0.1:9876/mcp"},
          {"HERDR_PANE_ID", "w1:p9"},
          {"HERDR_WORKSPACE_ID", "w1"}
        ]
      )

    assert %{"name" => "jarvis2_run", "config" => config} = Jason.decode!(output)
    assert config["url"] == "http://127.0.0.1:9876/mcp"
    assert config["headers"] == %{"X-Herdr-Pane" => "w1:p9", "X-Herdr-Workspace" => "w1"}
    assert config["exposure"] == "codemode"

    for name <-
          ~w(ask_human request_approval wait_for_answer submit_result ask_questions submit_deliverable) do
      assert config["toolExposure"][name] == "direct"
    end
  end

  test "Pi project configuration exposes the intended safe tools" do
    server =
      File.read!(Path.expand("../../../.pi/mcp.json", __DIR__))
      |> Jason.decode!()
      |> get_in(["mcpServers", "jarvis2"])

    assert server["exposure"] == "codemode"
    assert server["headers"]["X-Herdr-Pane"] == ~S(${HERDR_PANE_ID})
    refute Map.has_key?(server["headers"], "Authorization")
    assert server["toolExposure"]["whoami"] == "direct"
    refute Map.has_key?(server["toolExposure"], "elixir_eval")
    refute Map.has_key?(server["toolExposure"], "report_status")
  end
end
