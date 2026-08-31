defmodule Passby.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/altenwald/passby"

  def project do
    [
      app: :passby,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "A 100% Elixir, 0-dependency HTTP mock server for testing HTTP clients. A lightweight drop-in replacement for Bypass.",
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: [summary: [threshold: 90]],
      homepage_url: @source_url,
      source_url: @source_url,
      preferred_cli_env: [
        check: :test
      ]
    ]
  end

  defp dialyzer do
    [
      plt_local_path: ".plts",
      plt_core_path: ".plts",
      plt_add_apps: [:inets, :ssl, :public_key, :logger, :ex_unit],
      flags: [:error_handling, :unknown]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key],
      mod: {Passby.Application, []}
    ]
  end

  defp package do
    [
      files: ~w(lib mix.exs README* LICENSE* .formatter.exs),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/passby"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "LICENSE"]
    ]
  end

  defp deps do
    [
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:doctor, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end
end
