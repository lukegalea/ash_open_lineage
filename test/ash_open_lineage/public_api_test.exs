# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.PublicApiTest do
  @moduledoc "AshOpenLineage.emit/2 and AshOpenLineage.fail/3 for non-Ash jobs."

  use ExUnit.Case, async: false

  alias AshOpenLineage.Transport.InMemory

  @gmail_job %{
    namespace: "ingestion",
    name: "gmail.sync",
    inputs: ["gmail"],
    outputs: [%{namespace: "warehouse", name: "raw.gmail_messages"}]
  }

  @run_id "f47ac10b-58cc-4372-a567-0e02b2c3d479"
  @parent_run_id "9f86d081-884c-4d63-a70a-1a3f0d0c0b1a"
  @root %{
    namespace: "agent",
    name: "morning.brief",
    run_id: "c4ca4238-a0b9-4e42-a817-b9d0f2a1c0e2"
  }

  setup do
    Application.put_env(:ash_open_lineage, :transport, InMemory)
    start_supervised!(InMemory)

    on_exit(fn ->
      Application.delete_env(:ash_open_lineage, :transport)
      Application.delete_env(:ash_open_lineage, :http_base_url)
    end)

    :ok
  end

  test "emit defaults to COMPLETE and defaults producer_name to namespace.name" do
    assert :ok = AshOpenLineage.emit(@gmail_job, run_id: @run_id, parent_run_id: @parent_run_id)

    assert [event] = InMemory.events()
    assert event["eventType"] == "COMPLETE"
    assert event["job"] == %{"namespace" => "ingestion", "name" => "gmail.sync"}
    assert event["inputs"] == [%{"namespace" => "ingestion", "name" => "gmail"}]
    assert event["outputs"] == [%{"namespace" => "warehouse", "name" => "raw.gmail_messages"}]
    assert event["run"]["runId"] == @run_id
    assert event["run"]["facets"]["parent"]["run"]["runId"] == @parent_run_id

    assert event["run"]["facets"]["ashOpenLineageProducer"]["producer_name"] ==
             "ingestion.gmail.sync"
  end

  test "emit START, and the root sub-object flows into the parent facet" do
    assert :ok =
             AshOpenLineage.emit(@gmail_job,
               event_type: :start,
               run_id: @run_id,
               parent_run_id: @parent_run_id,
               root: @root
             )

    assert [event] = InMemory.events()
    assert event["eventType"] == "START"

    assert event["run"]["facets"]["parent"]["root"] == %{
             "job" => %{"namespace" => "agent", "name" => "morning.brief"},
             "run" => %{"runId" => @root.run_id}
           }
  end

  test "START and COMPLETE share a run when the same run_id is passed" do
    AshOpenLineage.emit(@gmail_job, event_type: :start, run_id: @run_id)
    AshOpenLineage.emit(@gmail_job, event_type: :complete, run_id: @run_id)

    run_ids = Enum.map(InMemory.events(), & &1["run"]["runId"])
    assert run_ids == [@run_id, @run_id]
  end

  test "without an explicit run_id, each event is its own run" do
    AshOpenLineage.emit(@gmail_job, event_type: :start)
    AshOpenLineage.emit(@gmail_job, event_type: :complete)

    assert [%{"run" => %{"runId" => first}}, %{"run" => %{"runId" => second}}] =
             InMemory.events()

    refute first == second
  end

  test "fail emits FAIL with the reason in the error facet" do
    assert :ok =
             AshOpenLineage.fail(@gmail_job, "tap crashed: Google API 410 gone", run_id: @run_id)

    assert [event] = InMemory.events()
    assert event["eventType"] == "FAIL"
    assert event["run"]["runId"] == @run_id
    assert event["run"]["facets"]["error"]["errorMessage"] == "tap crashed: Google API 410 gone"
  end

  test "fail accepts exceptions and any term" do
    AshOpenLineage.fail(@gmail_job, RuntimeError.exception("connection refused"))
    AshOpenLineage.fail(@gmail_job, {:exit_code, 17})

    assert [
             %{"run" => %{"facets" => %{"error" => %{"errorMessage" => "connection refused"}}}},
             %{"run" => %{"facets" => %{"error" => %{"errorMessage" => "{:exit_code, 17}"}}}}
           ] = InMemory.events()
  end

  test "emit refuses :fail — that is fail/3's job" do
    assert_raise ArgumentError, ~r/fail\/3/, fn ->
      AshOpenLineage.emit(@gmail_job, event_type: :fail)
    end
  end

  test "a descriptor without :namespace/:name is an ArgumentError, not a KeyError" do
    assert_raise ArgumentError, ~r/requires :namespace and :name/, fn ->
      AshOpenLineage.emit(%{name: "gmail.sync"})
    end

    assert_raise ArgumentError, ~r/must be a String/, fn ->
      AshOpenLineage.emit(%{namespace: :ingestion, name: "gmail.sync"})
    end
  end

  test "the Req transport reports a missing base url as an error, never a raise" do
    Application.delete_env(:ash_open_lineage, :http_base_url)

    assert {:error, :http_base_url_not_configured} =
             AshOpenLineage.Transport.Req.send(%{"event" => true})
  end
end
