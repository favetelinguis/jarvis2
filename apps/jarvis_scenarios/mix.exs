defmodule JarvisScenarios.MixProject do
  use Mix.Project

  def project do
    [
      app: :jarvis_scenarios,
      version: "0.1.0",
      elixir: "~> 1.20",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: [{:jarvis_core, in_umbrella: true}]
    ]
  end
end
