defmodule Jarvis2.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      apps: [:herdr_client, :jarvis2],
      version: System.get_env("JARVIS2_VERSION", "0.1.0"),
      start_permanent: Mix.env() == :prod,
      releases: [
        jarvis2: [
          applications: [jarvis2: :permanent],
          include_executables_for: [:unix],
          steps: [:assemble, &package_resources/1]
        ]
      ],
      deps: deps()
    ]
  end

  defp package_resources(release) do
    share = Path.join(release.path, "share")
    File.rm_rf!(share)
    File.mkdir_p!(share)
    for dir <- ~w(roles skills), do: File.cp_r!(dir, Path.join(share, dir))
    File.cp!(".pi/jarvis2-run.js", Path.join(share, "jarvis2-run.js"))
    release
  end

  defp deps do
    [{:credo, "~> 1.7", only: [:dev, :test], runtime: false}]
  end
end
