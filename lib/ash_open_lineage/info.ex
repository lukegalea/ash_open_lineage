# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Info do
  @moduledoc """
  Introspection for the `lineage` DSL section, plus the derived helpers the
  notifier and the public API build on.

  The `lineage_*` functions are generated from the section schema by
  `Spark.InfoGenerator`; the functions below them are this library's own
  derivations (namespace fallback, resource singular, dataset from the postgres
  table declaration).
  """

  use Spark.InfoGenerator, extension: AshOpenLineage.Extension, sections: [:lineage]

  @doc """
  The namespace this resource's jobs and datasets live in: the `namespace` DSL
  option when set, otherwise derived from the resource's domain module name —
  the last segment, underscored (`MyApp.Support` becomes `"support"`).

  A resource without a domain falls back to its own last segment. Prefer an
  explicit `namespace` there: a fallback named after the resource collides with
  the job name's own resource segment and reads as a mistake, not a convention.
  """
  @spec job_namespace(Ash.Resource.t() | Spark.Dsl.t()) :: String.t()
  def job_namespace(resource) do
    # Spark 2.7's generated scalar accessors return `{:ok, value} | :error`;
    # the `namespace` option is optional, so unwrap rather than use the bang.
    case lineage_namespace(resource) do
      {:ok, namespace} when is_binary(namespace) -> namespace
      _ -> derive_namespace(resource)
    end
  end

  @doc """
  The last segment of the resource module, underscored — the `ticket` in the
  job name `"ticket.create"`.
  """
  @spec resource_singular(Ash.Resource.t()) :: String.t()
  def resource_singular(resource) when is_atom(resource) do
    resource |> Module.split() |> List.last() |> Macro.underscore()
  end

  @doc """
  The resource's postgres table as an OpenLineage dataset descriptor, or `nil`
  when the resource declares no `postgres do table end` (including when
  ash_postgres is not loaded).

  The dataset name is schema-qualified when the resource declares a schema
  (`"staging.tickets"`), plain otherwise (`"tickets"`). The dataset namespace is
  the job namespace (`job_namespace/1`) — one namespace per resource keeps the
  graph connected for consumers that don't know Postgres URLs.

  There is deliberately no fallback: emitting a guessed dataset name writes a
  fiction into the catalogue that is worse than an absent node.
  """
  @spec resource_dataset(Ash.Resource.t()) :: %{String.t() => String.t()} | nil
  def resource_dataset(resource) do
    if match?({:module, _}, Code.ensure_compiled(AshPostgres.DataLayer)) do
      table = AshPostgres.DataLayer.Info.table(resource)

      if is_binary(table) do
        %{
          "namespace" => job_namespace(resource),
          "name" => relation(resource, table)
        }
      end
    end
  end

  defp relation(resource, table) do
    case AshPostgres.DataLayer.Info.schema(resource) do
      schema when is_binary(schema) -> "#{schema}.#{table}"
      _ -> table
    end
  end

  defp derive_namespace(resource) do
    case Ash.Resource.Info.domain(resource) do
      nil ->
        resource_singular(resource)

      domain ->
        domain |> Module.split() |> List.last() |> Macro.underscore()
    end
  end
end
