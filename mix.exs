defmodule Elv.MixProject do
  use Mix.Project

  def project do
    [
      app: :elv,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Elv.CLI, name: "elv"],
      description: "Elixir Luv V: a polished Julia-style REPL shell for V.",
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    []
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/TomLo-FStack/elixir-luv-v"},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
