defmodule Jarvis2.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      releases: [jarvis2: [applications: [jarvis_web: :permanent]]],
      deps: deps()
    ]
  end

  defp deps do
    [{:credo, "~> 1.7", only: [:dev, :test], runtime: false}]
  end
end
