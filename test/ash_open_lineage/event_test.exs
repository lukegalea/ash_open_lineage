# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.EventTest do
  @moduledoc """
  Golden fixtures: the serialized RunEvent maps are compared against expected
  JSON structures in full. These pin the wire shape; the schema-conformance
  suite pins it against the vendored spec.
  """

  use ExUnit.Case, async: true

  import AshOpenLineage.Event, only: [run_event: 1]

  @producer "https://github.com/lukegalea/ash_open_lineage"
  @run_event_schema_url "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/RunEvent"
  @base_facet_schema_url "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/BaseFacet"
  @producer_facet_schema_url "https://github.com/lukegalea/ash_open_lineage/blob/main/priv/openlineage/facets/ash_open_lineage_producer_facet.json"

  @time ~U[2026-01-01T00:00:00Z]
  @run_id "f47ac10b-58cc-4372-a567-0e02b2c3d479"
  @parent_run_id "9f86d081-884c-4d63-a70a-1a3f0d0c0b1a"
  @root_run_id "c4ca4238-a0b9-4e42-a817-b9d0f2a1c0e2"

  defp producer_facet(producer_name, producer \\ @producer) do
    %{
      "_producer" => producer,
      "_schemaURL" => @producer_facet_schema_url,
      "producer_name" => producer_name
    }
  end

  test "START without parent facet — golden" do
    event =
      run_event(
        event_type: :start,
        event_time: @time,
        job_namespace: "ingestion",
        job_name: "gmail.sync",
        inputs: ["gmail"],
        outputs: [{"warehouse", "raw.gmail_messages"}],
        run_id: @run_id,
        parent_run_id: nil,
        producer_name: "ingestion.gmail.sync"
      )

    assert event == %{
             "eventTime" => "2026-01-01T00:00:00Z",
             "eventType" => "START",
             "producer" => @producer,
             "schemaURL" => @run_event_schema_url,
             "inputs" => [%{"namespace" => "ingestion", "name" => "gmail"}],
             "outputs" => [%{"namespace" => "warehouse", "name" => "raw.gmail_messages"}],
             "job" => %{"namespace" => "ingestion", "name" => "gmail.sync"},
             "run" => %{
               "runId" => @run_id,
               "facets" => %{"ashOpenLineageProducer" => producer_facet("ingestion.gmail.sync")}
             }
           }
  end

  test "COMPLETE with parent facet and root — golden" do
    event =
      run_event(
        event_type: :complete,
        event_time: @time,
        job_namespace: "calendar",
        job_name: "calendar_event.create",
        inputs: [],
        outputs: [%{namespace: "warehouse", name: "ol.calendar_events"}],
        run_id: @run_id,
        parent_run_id: @parent_run_id,
        root: %{namespace: "agent", name: "morning.brief", run_id: @root_run_id},
        producer_name: "calendar.calendar_event.create"
      )

    assert event == %{
             "eventTime" => "2026-01-01T00:00:00Z",
             "eventType" => "COMPLETE",
             "producer" => @producer,
             "schemaURL" => @run_event_schema_url,
             "inputs" => [],
             "outputs" => [%{"namespace" => "warehouse", "name" => "ol.calendar_events"}],
             "job" => %{"namespace" => "calendar", "name" => "calendar_event.create"},
             "run" => %{
               "runId" => @run_id,
               "facets" => %{
                 "parent" => %{
                   "_producer" => @producer,
                   "_schemaURL" => @base_facet_schema_url,
                   "run" => %{"runId" => @parent_run_id},
                   "root" => %{
                     "job" => %{"namespace" => "agent", "name" => "morning.brief"},
                     "run" => %{"runId" => @root_run_id}
                   }
                 },
                 "ashOpenLineageProducer" => producer_facet("calendar.calendar_event.create")
               }
             }
           }
  end

  test "COMPLETE with parent facet, no root — minimal valid parent form" do
    event =
      run_event(
        event_type: :complete,
        event_time: @time,
        job_namespace: "calendar",
        job_name: "calendar_event.update",
        run_id: @run_id,
        parent_run_id: @parent_run_id,
        producer_name: "calendar.calendar_event.update"
      )

    assert event["run"]["facets"]["parent"] == %{
             "_producer" => @producer,
             "_schemaURL" => @base_facet_schema_url,
             "run" => %{"runId" => @parent_run_id}
           }

    refute Map.has_key?(event["run"]["facets"]["parent"], "root")
  end

  test "FAIL with error facet — golden" do
    event =
      run_event(
        event_type: :fail,
        event_time: @time,
        job_namespace: "ingestion",
        job_name: "gmail.sync",
        inputs: ["gmail"],
        run_id: @run_id,
        producer_name: "ingestion.gmail.sync",
        error_message: "tap crashed: Google API 410 gone"
      )

    assert event == %{
             "eventTime" => "2026-01-01T00:00:00Z",
             "eventType" => "FAIL",
             "producer" => @producer,
             "schemaURL" => @run_event_schema_url,
             "inputs" => [%{"namespace" => "ingestion", "name" => "gmail"}],
             "outputs" => [],
             "job" => %{"namespace" => "ingestion", "name" => "gmail.sync"},
             "run" => %{
               "runId" => @run_id,
               "facets" => %{
                 "ashOpenLineageProducer" => producer_facet("ingestion.gmail.sync"),
                 "error" => %{
                   "_producer" => @producer,
                   "_schemaURL" => @base_facet_schema_url,
                   "errorMessage" => "tap crashed: Google API 410 gone"
                 }
               }
             }
           }
  end

  test "dataset descriptors: bare string lands in the job namespace; map with facets gets string keys" do
    event =
      run_event(
        event_type: :complete,
        event_time: @time,
        job_namespace: "ingestion",
        job_name: "gmail.sync",
        inputs: [%{name: "gmail", facets: %{schema: %{"fields" => ["id"]}}}],
        outputs: [%{name: "raw.gmail_messages", facets: %{dataSource: %{"uri" => "imap://x"}}}],
        run_id: @run_id,
        producer_name: "ingestion.gmail.sync"
      )

    assert event["inputs"] == [
             %{
               "namespace" => "ingestion",
               "name" => "gmail",
               "facets" => %{"schema" => %{"fields" => ["id"]}}
             }
           ]

    assert event["outputs"] == [
             %{
               "namespace" => "ingestion",
               "name" => "raw.gmail_messages",
               "facets" => %{"dataSource" => %{"uri" => "imap://x"}}
             }
           ]
  end

  test ":producer override flows into the top-level producer and every facet's _producer" do
    event =
      run_event(
        event_type: :fail,
        event_time: @time,
        job_namespace: "ns",
        job_name: "job",
        parent_run_id: @parent_run_id,
        producer: "https://example.com/my-app",
        producer_name: "ns.job",
        error_message: "boom"
      )

    assert event["producer"] == "https://example.com/my-app"
    assert event["run"]["facets"]["parent"]["_producer"] == "https://example.com/my-app"
    assert event["run"]["facets"]["error"]["_producer"] == "https://example.com/my-app"

    assert event["run"]["facets"]["ashOpenLineageProducer"]["_producer"] ==
             "https://example.com/my-app"
  end

  test ":run_id defaults to the correlation provider, freshly per event" do
    first =
      run_event(event_type: :start, job_namespace: "ns", job_name: "job", producer_name: "ns.job")

    second =
      run_event(event_type: :start, job_namespace: "ns", job_name: "job", producer_name: "ns.job")

    uuid = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert first["run"]["runId"] =~ uuid
    assert second["run"]["runId"] =~ uuid
    refute first["run"]["runId"] == second["run"]["runId"]
  end

  test "an unknown event type is a bug and raises" do
    assert_raise ArgumentError, ~r/invalid :event_type/, fn ->
      run_event(
        event_type: :running,
        job_namespace: "ns",
        job_name: "job",
        producer_name: "ns.job"
      )
    end
  end

  test "an eventTime binary passes through; default is ISO8601 UTC" do
    explicit =
      run_event(
        event_type: :complete,
        event_time: "2026-02-03T04:05:06.000007Z",
        job_namespace: "ns",
        job_name: "job",
        producer_name: "ns.job"
      )

    assert explicit["eventTime"] == "2026-02-03T04:05:06.000007Z"

    defaulted =
      run_event(
        event_type: :complete,
        job_namespace: "ns",
        job_name: "job",
        producer_name: "ns.job"
      )

    assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(defaulted["eventTime"])
  end
end
