defmodule Jarvis2.PiConfigTest do
  use ExUnit.Case, async: false

  test "Pi project configuration exposes the intended safe tools" do
    server =
      File.read!(Path.expand("../../../.pi/mcp.json", __DIR__))
      |> Jason.decode!()
      |> get_in(["mcpServers", "jarvis2"])

    assert server["exposure"] == "codemode"
    assert server["headers"]["X-Herdr-Pane"] == ~S(${HERDR_PANE_ID})
    assert server["headers"]["Authorization"] =~ "~/.local/state/jarvis2/token"
    assert server["toolExposure"]["whoami"] == "direct"
    refute Map.has_key?(server["toolExposure"], "elixir_eval")
  end
end
