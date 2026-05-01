defmodule Schooner.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/ausimian/schooner"

  def project do
    [
      app: :schooner,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [warnings_as_errors: true],
      package: package(),
      description: description(),
      docs: docs()
    ]
  end

  defp description do
    "An embeddable, sandboxed Scheme interpreter for the BEAM, targeting " <>
      "the r7rs-small language minus its mutable operations."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Schooner.Application, []}
    ]
  end

  defp deps do
    [
      {:nimble_options, "~> 1.1"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:publisho, "~> 1.0", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: @version,
      extras: [
        "README.md",
        "guides/embedding.md",
        "guides/host-functions.md",
        "guides/sandbox.md",
        "guides/deviations.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      filter_modules: &public_module?/2,
      groups_for_modules: [
        "Embedding API": [
          Schooner,
          Schooner.Environment,
          Schooner.Compiled,
          Schooner.Host,
          Schooner.Value,
          Schooner.Env,
          Schooner.Library,
          Schooner.Time
        ],
        Errors: [
          Schooner.Error,
          Schooner.Eval.Error,
          Schooner.Primitive.Error,
          Schooner.Host.TypeError,
          Schooner.Library.NotFoundError,
          Schooner.Lexer.Error,
          Schooner.Reader.Error,
          Schooner.Expander.Error
        ]
      ]
    ]
  end

  # Modules that should appear in the API Reference. Anything else is
  # an implementation detail — evaluator internals, primitive backing
  # modules, expander helpers, library plumbing — and is hidden from
  # the generated docs even when its individual @moduledoc is set.
  @public_modules MapSet.new([
                    Schooner,
                    Schooner.Environment,
                    Schooner.Compiled,
                    Schooner.Host,
                    Schooner.Host.TypeError,
                    Schooner.Value,
                    Schooner.Env,
                    Schooner.Library,
                    Schooner.Library.NotFoundError,
                    Schooner.Time,
                    Schooner.Error,
                    Schooner.Eval.Error,
                    Schooner.Primitive.Error,
                    Schooner.Lexer.Error,
                    Schooner.Reader.Error,
                    Schooner.Expander.Error
                  ])

  defp public_module?(module, _metadata), do: MapSet.member?(@public_modules, module)

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
