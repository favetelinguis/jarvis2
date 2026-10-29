defmodule Jarvis2.MixProject do
  use Mix.Project

  def project do
    [
      app: :jarvis_web,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Jarvis2.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:jarvis_core, in_umbrella: true},
      {:jarvis_mcp, in_umbrella: true},
      {:jarvis_scenarios, in_umbrella: true},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:anubis_mcp, "~> 2.2"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
