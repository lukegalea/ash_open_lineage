# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lukegalea/ash_open_lineage"

  def project do
    [
      app: :ash_open_lineage,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: """
      The first Elixir OpenLineage emitter. A Spark extension + Ash.Notifier that
      emits spec 2-0-2 RunEvents for resource actions, and a small public API for
      non-Ash jobs. Facets carry structural names only — never actor, tenant or
      data values.
      """,
      source_url: @source_url,
      deps: deps(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # test/support carries the test resources (ETS-backed and postgres-declared),
  # the fixture domain, and the leak-check assertion helper.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:spark, "~> 2.0"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      # Optional deliberately: the notifier derives datasets from the resource's
      # `postgres do table end` declaration when ash_postgres is present, and
      # emits no dataset when it is not. Consumed via Code.ensure_compiled?/1.
      {:ash_postgres, "~> 2.0", optional: true},
      # Required by Spark.Formatter, which formats the DSL blocks.
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      # Spec-conformance tests validate built events against the vendored
      # OpenLineage 2-0-2 schema. Test-only: a consumer never validates here.
      {:ex_json_schema, "~> 0.10", only: [:dev, :test]}
    ]
  end

  defp package do
    [
      maintainers: ["Luke Galea"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE usage-rules.md CHANGELOG.md)
    ]
  end
end
