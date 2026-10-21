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

  describe ":meta" do
    import AshOpenLineage.TestSupport.LeakCheck, only: [assert_clean!: 2]

    @meta %{tenant: "tenant-meta-only-31", pipeline: "pipeline-meta-only-7"}

    test "emit hands :meta to a send/2 transport and keeps it out of the event" do
      assert :ok = AshOpenLineage.emit(@gmail_job, run_id: @run_id, meta: @meta)

      assert [{event, meta}] = InMemory.entries()
      assert meta == @meta
      assert event["eventType"] == "COMPLETE"
      event |> Jason.encode!() |> Jason.decode!() |> then(&assert_clean!(&1, forbidden_meta()))
      assert_clean!(event, forbidden_meta())
    end

    test "fail hands :meta to a send/2 transport and keeps it out of the event" do
      assert :ok = AshOpenLineage.fail(@gmail_job, "tap crashed", run_id: @run_id, meta: @meta)

      assert [{event, meta}] = InMemory.entries()
      assert meta == @meta
      assert event["eventType"] == "FAIL"
      event |> Jason.encode!() |> Jason.decode!() |> then(&assert_clean!(&1, forbidden_meta()))
    end

    test "without :meta a send/2 transport receives an empty map" do
      AshOpenLineage.emit(@gmail_job)
      AshOpenLineage.fail(@gmail_job, "boom")

      assert [{_, first_meta}, {_, second_meta}] = InMemory.entries()
      assert first_meta == %{}
      assert second_meta == %{}
    end

    test "a send/1-only transport still works, and :meta is dropped" do
      Application.put_env(:ash_open_lineage, :transport, AshOpenLineage.Test.Send1Transport)

      assert :ok = AshOpenLineage.emit(@gmail_job, meta: @meta)
      assert :ok = AshOpenLineage.fail(@gmail_job, "boom", meta: @meta)

      # the entries went in through InMemory.send/1: no meta came with them
      assert [{%{"eventType" => "COMPLETE"}, first_meta}, {%{"eventType" => "FAIL"}, second_meta}] =
               InMemory.entries()

      assert first_meta == %{}
      assert second_meta == %{}
    end

    test "a non-map :meta is an ArgumentError" do
      assert_raise ArgumentError, ~r/:meta must be a map/, fn ->
        AshOpenLineage.emit(@gmail_job, meta: [tenant: "t-1"])
      end
    end

    defp forbidden_meta, do: Map.values(@meta)
  end

  test "the Req transport reports a missing base url as an error, never a raise" do
    Application.delete_env(:ash_open_lineage, :http_base_url)

    assert {:error, :http_base_url_not_configured} =
             AshOpenLineage.Transport.Req.send(%{"event" => true})
  end
end
