# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Dsl do
  @moduledoc """
  The `lineage` DSL section added to resources by `AshOpenLineage.Extension`.
  """

  @lineage %Spark.Dsl.Section{
    name: :lineage,
    describe: """
    Configures OpenLineage emission for this resource.

    The extension installs `AshOpenLineage.Notifier`, which builds one spec
    2-0-2 RunEvent with `eventType: "COMPLETE"` for each successful action whose
    type is listed in `emit_on`, and hands it to `transport`.

    Job name is `"{resource_singular}.{action_name}"`; the namespace defaults to
    the resource's domain module name (last segment, underscored). The output
    dataset is derived from the resource's `postgres do table end` declaration —
    a resource without one contributes no dataset rather than a guess.
    """,
    examples: [
      """
      lineage do
        transport AshOpenLineage.Transport.Req
      end
      """,
      """
      lineage do
        transport MyApp.LineageTransport
        namespace "ash_enterprise"
        producer "https://github.com/lukegalea/ash_enterprise"
        emit_on [:create, :destroy]
      end
      """
    ],
    schema: [
      transport: [
        type: {:behaviour, AshOpenLineage.Transport},
        required: true,
        doc:
          "The module implementing `AshOpenLineage.Transport` that each RunEvent is handed to. " <>
            "`AshOpenLineage.Transport.Req` posts to an OpenLineage-compatible HTTP endpoint; " <>
            "`AshOpenLineage.Transport.InMemory` collects events for tests and development."
      ],
      producer: [
        type: :string,
        default: "https://github.com/lukegalea/ash_open_lineage",
        doc:
          "URI identifying the producer of these events (top-level `producer` and the facets' " <>
            "`_producer`). Set this to your own application's URI when you adopt the extension."
      ],
      namespace: [
        type: :string,
        doc:
          "The OpenLineage namespace for this resource's jobs and datasets. Defaults to the " <>
            "resource's domain module name — the last segment, underscored (domain `MyApp.Calendar` " <>
            "produces namespace `\"calendar\"`). Override when the namespace has to match what " <>
            "other producers writing to the same catalogue use, or the graph disconnects at the join."
      ],
      emit_on: [
        type: {:wrap_list, {:one_of, [:create, :update, :destroy]}},
        default: [:create, :update, :destroy],
        doc:
          "Action types that emit a COMPLETE RunEvent. Reads are never emitted. START/FAIL for " <>
            "resource actions are deliberately out of scope (ADR 0012): the host emits those " <>
            "itself via `AshOpenLineage.emit/2` and `AshOpenLineage.fail/2` for jobs it drives."
      ]
    ]
  }

  @doc false
  def lineage, do: @lineage
end
