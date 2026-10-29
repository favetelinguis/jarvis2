defmodule Jarvis2.PluginTest do
  use ExUnit.Case, async: false

  test "manifest commands and link handlers reference declared entrypoints" do
    {output, 0} =
      System.cmd("/usr/bin/python3", [
        "-c",
        "import json,tomllib; print(json.dumps(tomllib.load(open('#{Path.expand("../../../herdr-plugin.toml", __DIR__)}','rb'))))"
      ])

    manifest = Jason.decode!(output)
    assert manifest["id"] == "favetelinguis.jarvis2"
    assert manifest["min_herdr_version"] == "0.9.0"
    actions = Map.new(manifest["actions"], &{&1["id"], &1})

    for id <-
          ~w(start-server open-dashboard probe-context layout-dev focus-mode focus-mode-off review-diff new-task send-to-agent issue-link docs-link) do
      assert actions[id]["command"] == ["/usr/bin/python3", "bin/forward", "action", id]
    end

    for event <- manifest["events"] do
      assert event["command"] == ["/usr/bin/python3", "bin/forward", "event", event["on"]]
    end

    for handler <- manifest["link_handlers"], do: assert(Map.has_key?(actions, handler["action"]))
    assert Enum.any?(manifest["panes"], &(&1["id"] == "server"))

    for id <- ~w(dashboard picker docs),
        do: assert(Enum.any?(manifest["panes"], &(&1["id"] == id and &1["placement"] == "popup")))
  end

  test "docs popup passes only valid HexDocs URLs to the browser" do
    dir = Path.join(Application.fetch_env!(:jarvis2, :state_dir), "fake-browser")
    File.mkdir_p!(dir)
    binary = Path.join(dir, "w3m")
    File.write!(binary, "#!/bin/sh\nprintf '%s' \"$1\"\n")
    File.chmod!(binary, 0o700)
    url = "https://hexdocs.pm/elixir/Enum.html#map/2"

    assert {^url, 0} =
             System.cmd(Path.expand("../../../bin/docs", __DIR__), [],
               env: [{"PATH", dir}, {"JARVIS2_DOCS_URL", url}]
             )

    assert {_, 1} =
             System.cmd(Path.expand("../../../bin/docs", __DIR__), [],
               env: [{"PATH", dir}, {"JARVIS2_DOCS_URL", "https://hexdocs.pm@evil.test/x"}],
               stderr_to_stdout: true
             )
  end

  test "Pi project configuration exposes the intended safe tools" do
    server =
      File.read!(Path.expand("../../../.pi/mcp.json", __DIR__))
      |> Jason.decode!()
      |> get_in(["mcpServers", "jarvis2"])

    assert server["exposure"] == "codemode"
    assert server["headers"]["X-Herdr-Pane"] == ~S(${HERDR_PANE_ID})
    assert server["toolExposure"]["whoami"] == "direct"
    assert server["toolExposure"]["elixir_eval"] == "hidden"
  end

  test "start-server opens the server entrypoint without requiring the app" do
    dir = Path.join(Application.fetch_env!(:jarvis2, :state_dir), "fake-herdr")
    File.mkdir_p!(dir)
    binary = Path.join(dir, "herdr")
    output = Path.join(dir, "args")
    File.write!(binary, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\n")
    File.chmod!(binary, 0o700)
    env = [{"HERDR_BIN_PATH", binary}, {"CAPTURE", output}]

    assert {_, 0} =
             System.cmd(Path.expand("../../../bin/forward", __DIR__), ["action", "start-server"],
               env: env,
               stderr_to_stdout: true
             )

    assert File.read!(output) |> String.split("\n", trim: true) == [
             "plugin",
             "pane",
             "open",
             "--plugin",
             "favetelinguis.jarvis2",
             "--entrypoint",
             "server",
             "--placement",
             "split",
             "--no-focus"
           ]
  end
end
