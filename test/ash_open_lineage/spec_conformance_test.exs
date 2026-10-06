# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.SpecConformanceTest do
  @moduledoc """
  Validates built events against the vendored OpenLineage spec.

  `priv/openlineage/s/run-event.json` is the OpenLineage **2-0-2** schema,
  vendored verbatim from
  `https://openlineage.io/spec/2-0-2/OpenLineage.json` — the consolidated model
  whose `$defs/RunEvent` defines the RunEvent (the historical
  `.../spec/2-0-2/OpenLineageRunEvent.json` URL 404s today; the consolidated
  file is where that content lives now, self-contained, no remote refs).
  """

  use ExUnit.Case, async: true

  # ex_json_schema speaks drafts 4/6/7. The vendored 2-0-2 schema is written in
  # 2020-12 but uses no 2020-12-only constructs (its `$defs` are referenced by
  # plain JSON pointer), so it is resolved under draft-7 semantics by dropping
  # the `$schema` key at load time only — the vendored file stays verbatim.
  @schema File.read!("priv/openlineage/s/run-event.json")
          |> Jason.decode!()
          |> Map.delete("$schema")
          |> ExJsonSchema.Schema.resolve()

  @time ~U[2026-01-01T00:00:00Z]
  @run_id "f47ac10b-58cc-4372-a567-0e02b2c3d479"
  @parent_run_id "9f86d081-884c-4d63-a70a-1a3f0d0c0b1a"

  defp assert_conforms(event) do
    # Encode/decode so validation sees exactly what hits the wire.
    json = event |> Jason.encode!() |> Jason.decode!()

    case ExJsonSchema.Validator.valid?(@schema, json) do
      true ->
        assert true

      false ->
        flunk("""
        event does not conform to the vendored OpenLineage 2-0-2 schema:
        #{inspect(ExJsonSchema.Validator.validate(@schema, json))}

        event: #{Jason.encode!(json, pretty: true)}
        """)
    end
  end

  defp run_event(opts) do
    AshOpenLineage.Event.run_event(
      Keyword.merge(
        [
          event_time: @time,
          run_id: @run_id,
          job_namespace: "ingestion",
          job_name: "gmail.sync",
          producer_name: "ingestion.gmail.sync"
        ],
        opts
      )
    )
  end

  test "START conforms" do
    assert_conforms(
      run_event(event_type: :start, inputs: ["gmail"], outputs: [{"warehouse", "raw.gmail"}])
    )
  end

  test "COMPLETE conforms" do
    assert_conforms(
      run_event(
        event_type: :complete,
        inputs: ["gmail"],
        # dataset facets must themselves satisfy BaseFacet
        outputs: [
          %{
            name: "raw.gmail",
            facets: %{
              schema: %{
                "_producer" => "https://github.com/lukegalea/ash_open_lineage",
                "_schemaURL" =>
                  "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/DatasetFacet",
                "fields" => []
              }
            }
          }
        ]
      )
    )
  end

  test "FAIL conforms, with error facet" do
    assert_conforms(run_event(event_type: :fail, error_message: "tap crashed: 410 gone"))
  end

  test "parent facet (with and without root) conforms" do
    assert_conforms(run_event(event_type: :complete, parent_run_id: @parent_run_id))

    assert_conforms(
      run_event(
        event_type: :complete,
        parent_run_id: @parent_run_id,
        root: %{namespace: "agent", name: "morning.brief", run_id: @run_id}
      )
    )
  end

  test "producer override conforms" do
    assert_conforms(run_event(event_type: :complete, producer: "https://example.com/app"))
  end

  test "the facet schema this library ships also validates its own facet" do
    facet_schema =
      File.read!("priv/openlineage/facets/ash_open_lineage_producer_facet.json")
      |> Jason.decode!()
      |> Map.delete("$schema")
      |> ExJsonSchema.Schema.resolve()

    facet = %{
      "_producer" => "https://github.com/lukegalea/ash_open_lineage",
      "_schemaURL" =>
        "https://github.com/lukegalea/ash_open_lineage/blob/main/priv/openlineage/facets/ash_open_lineage_producer_facet.json",
      "producer_name" => "catalog.thing.create"
    }

    assert ExJsonSchema.Validator.valid?(facet_schema, facet)
  end
end
