defmodule JarvisCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :jarvis_core,
      version: "0.1.0",
      elixir: "~> 1.20",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [{:herdr_client, in_umbrella: true}, {:jason, "~> 1.4"}, {:phoenix_pubsub, "~> 2.1"}]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
