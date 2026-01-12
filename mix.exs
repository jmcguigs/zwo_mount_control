defmodule ZwoController.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/jmcguigs/zwo_controller"

  def project do
    [
      app: :zwo_controller,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ZwoController",
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ZwoController.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:circuits_uart, "~> 1.5"},
      {:space_dust, "~> 0.2.1"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Elixir library for controlling ZWO AM5 telescope mounts via serial communication.
    Supports GoTo/slewing, tracking, autoguiding, Alt-Az and Equatorial modes,
    and satellite tracking with TLE propagation.
    """
  end

  defp package do
    [
      name: "zwo_controller",
      files: ~w(lib examples .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Jack McGuigan"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        "Core": [ZwoController, ZwoController.Mount],
        "Testing": [ZwoController.Mock],
        "Utilities": [
          ZwoController.Coordinates,
          ZwoController.Discovery,
          ZwoController.Protocol
        ],
        "Advanced": [ZwoController.SatelliteTracker]
      ]
    ]
  end
end
