defmodule Jarvis2.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:herdr_client, :jarvis2],
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      releases: [jarvis2: [applications: [jarvis2: :permanent]]],
      deps: deps()
    ]
  end

  defp deps do
    [{:credo, "~> 1.7", only: [:dev, :test], runtime: false}]
  end
end
