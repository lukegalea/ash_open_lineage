# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.NotifierTest do
  @moduledoc """
  The extension end-to-end on ETS-backed resources with the InMemory transport.

  On ash ≥ 3.34 notifications dispatch automatically after successful actions;
  on earlier 3.x the host opts in per call with `notify?: true`. These tests run
  against the resolved ash and say nothing extra — the notifier hears whatever
  the host's Ash version delivers.
  """

  use ExUnit.Case, async: false

  alias AshOpenLineage.Transport.InMemory
  alias AshOpenLineage.Test.{Correlation, ParentId, Selective, Thing}

  @producer "https://github.com/lukegalea/ash_open_lineage"

  setup do
    start_supervised!(InMemory)

    on_exit(fn ->
      Application.delete_env(:ash_open_lineage, :correlation_provider)
      Application.delete_env(:ash_open_lineage, :parent_id_provider)
    end)

    :ok
  end

  test "create emits one COMPLETE RunEvent with derived namespace and job name" do
    Ash.create!(Ash.Changeset.for_create(Thing, :create, %{name: "widget"}))

    assert [event] = InMemory.events()
    assert event["eventType"] == "COMPLETE"
    assert event["job"] == %{"namespace" => "catalog", "name" => "thing.create"}

    # ETS resource: no postgres table, so no dataset is guessed into the event
    assert event["inputs"] == []
    assert event["outputs"] == []

    producer_facet = event["run"]["facets"]["ashOpenLineageProducer"]
    assert producer_facet["producer_name"] == "catalog.thing.create"
    assert producer_facet["_producer"] == @producer

    # derived runId: sha256-based, well-formed UUID shape (no version nibble)
    assert event["run"]["runId"] =~
           ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    refute Map.has_key?(event["run"]["facets"], "parent")
  end

  test "destroy emits with no dataset input when the resource has no table" do
    thing = Ash.create!(Ash.Changeset.for_create(Thing, :create, %{name: "widget"}))
    InMemory.clear()

    Ash.destroy!(thing)

    assert [%{"job" => %{"name" => "thing.destroy"}, "inputs" => [], "outputs" => []}] =
             InMemory.events()
  end

  test "emit_on restricts emission: update is silent when only :create is listed" do
    selective =
      Ash.create!(Ash.Changeset.for_create(Selective, :create, %{name: "widget"}))

    assert [_create_event] = InMemory.events()
    InMemory.clear()

    Ash.update!(Ash.Changeset.for_update(selective, :update, %{name: "gadget"}))

    assert InMemory.events() == []
  end

  test "configured producer and namespace flow through" do
    Ash.create!(Ash.Changeset.for_create(Selective, :create, %{name: "widget"}))

    assert [event] = InMemory.events()
    assert event["producer"] == "https://example.com/selective-producer"
    assert event["job"] == %{"namespace" => "selective_ns", "name" => "selective.create"}

    assert event["run"]["facets"]["ashOpenLineageProducer"]["_producer"] ==
             "https://example.com/selective-producer"
  end

  test "reads are never emitted" do
    Ash.read!(Thing)
    assert InMemory.events() == []
  end

  test "depth above zero adds the parent facet from the parent id provider" do
    Application.put_env(:ash_open_lineage, :correlation_provider, Correlation)
    Application.put_env(:ash_open_lineage, :parent_id_provider, ParentId)

    Ash.create!(Ash.Changeset.for_create(Thing, :create, %{name: "widget"}))

    assert [event] = InMemory.events()
    assert event["run"]["runId"] == derived_run_id(Correlation.id(), "catalog", "thing.create")
    assert event["run"]["facets"]["parent"]["run"]["runId"] == ParentId.parent_id()
  end

  test "depth above zero with no parent id provider omits the parent facet rather than fabricating one" do
    Application.put_env(:ash_open_lineage, :correlation_provider, Correlation)

    Ash.create!(Ash.Changeset.for_create(Thing, :create, %{name: "widget"}))

    assert [event] = InMemory.events()
    assert event["run"]["runId"] == derived_run_id(Correlation.id(), "catalog", "thing.create")
    refute Map.has_key?(event["run"]["facets"], "parent")
  end

  test "dataset derivation: plain table, schema-qualified table, none" do
    alias AshOpenLineage.Test.{PostgresThing, SchemaedThing}

    assert AshOpenLineage.Info.resource_dataset(PostgresThing) == %{
             "namespace" => "catalog",
             "name" => "ol_test_things"
           }

    assert AshOpenLineage.Info.resource_dataset(SchemaedThing) == %{
             "namespace" => "catalog",
             "name" => "ol_staging.ol_schemaed_things"
           }

    assert AshOpenLineage.Info.resource_dataset(Thing) == nil
  end

  # Mirrors the notifier's derivation: one stable run per (correlation, job).
  defp derived_run_id(correlation_id, namespace, job_name) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12), _::binary>> =
      :crypto.hash(:sha256, correlation_id <> "/" <> namespace <> "/" <> job_name)
      |> Base.encode16(case: :lower)

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
