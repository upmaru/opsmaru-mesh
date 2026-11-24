defmodule OpsmaruMesh.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/upmaru/opsmaru-mesh"

  def project do
    [
      app: :opsmaru_mesh,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: false,
      deps: deps(),
      description:
        "Opsmaru mesh control plane: project-isolated cross-node networking for registered Incus hosts",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  # A pure library: no application callback, so loading or starting it
  # never creates processes, listeners, state or backend connections.
  def application do
    [extra_applications: [:logger, :crypto]]
  end

  # Hex is the only distribution route.
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [main: "readme", source_ref: "v#{@version}", extras: ["README.md"]]
  end

  # Ranges, not exact pins: consumers (central Opsmaru) resolve the exact
  # versions in their own lockfiles.
  defp deps do
    [
      {:opsmaru_incus, "~> 0.2.9"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
