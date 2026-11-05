# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.LeakTest do
  @moduledoc """
  The leak rule, red first.

  Facets carry structural names only. To make sure the assertion actually
  bites, it is first run against a deliberately-leaking map and must raise;
  only then is it trusted with real events built with an actor and a tenant
  injected into the changeset context, the actor option and the tenant option —
  every channel a facet could ever reach.

  Transports exporting `send/2` receive the tenant as host metadata; the
  `send/2` tests here show it arrives there while the event stays clean.
  """

  use ExUnit.Case, async: true

  import AshOpenLineage.TestSupport.LeakCheck, only: [assert_clean!: 2]

  alias AshOpenLineage.Event
  alias AshOpenLineage.Snapshot
  alias AshOpenLineage.Transport.InMemory
  alias AshOpenLineage.Test.Thing

  @tenant "tenant-acme-corp-42"
  @actor_id "actor-777"
  @actor_email "leaky.actor@example.com"

  setup do
    start_supervised!(InMemory)
    :ok
  end

  test "the leak check itself fails on a deliberately leaking map" do
    leaking = %{
      "run" => %{
        "facets" => %{"ashOpenLineageProducer" => %{"producer_name" => @tenant}}
      }
    }

    assert_raise ExUnit.AssertionError, ~r/leaks forbidden values/, fn ->
      assert_clean!(leaking, [@tenant])
    end

    # and it fires on values buried anywhere, keys included
    assert_raise ExUnit.AssertionError, fn ->
      assert_clean!(%{"job" => %{"namespace" => @actor_email}}, [@actor_email])
    end
  end

  test "no actor or tenant anywhere in a create event" do
    Ash.Changeset.for_create(Thing, :create, %{name: "harmless"})
    |> Ash.Changeset.set_context(%{actor_email: @actor_email, tenant_id: @tenant})
    |> Ash.create!(actor: %{id: @actor_id, email: @actor_email}, tenant: @tenant)

    [event] = InMemory.events()
    assert event["eventType"] == "COMPLETE"

    # round-trip through JSON so the assertion sees the wire form, too
    event |> Jason.encode!() |> Jason.decode!() |> then(&assert_clean!(&1, forbidden()))
    assert_clean!(event, forbidden())
  end

  test "no actor or tenant anywhere in a destroy event" do
    thing =
      Ash.create!(Ash.Changeset.for_create(Thing, :create, %{name: "harmless"}))

    InMemory.clear()

    Ash.destroy!(thing,
      actor: %{id: @actor_id, email: @actor_email},
      tenant: @tenant,
      context: %{actor_email: @actor_email, tenant_id: @tenant}
    )

    [event] = InMemory.events()
    assert event["eventType"] == "COMPLETE"
    event |> Jason.encode!() |> Jason.decode!() |> then(&assert_clean!(&1, forbidden()))
  end

  describe "host metadata for send/2 transports" do
    # The tenant reaches the transport as meta — that is the point of send/2 —
    # and the event built for the same action still carries none of it.

    test "a create's tenant reaches the transport's meta, not the event" do
      Ash.Changeset.for_create(Thing, :create, %{name: "harmless"})
      |> Ash.create!(actor: %{id: @actor_id, email: @actor_email}, tenant: @tenant)

      [{event, meta}] = InMemory.entries()

      assert meta == %{tenant: @tenant, resource: Thing, action: :create}

      event |> Jason.encode!() |> Jason.decode!() |> then(&assert_clean!(&1, forbidden()))
      assert_clean!(event, forbidden())
    end

    test "a destroy's tenant reaches the transport's meta, not the event" do
      thing =
        Ash.create!(Ash.Changeset.for_create(Thing, :create, %{name: "harmless"}),
          tenant: @tenant
        )

      InMemory.clear()

      Ash.destroy!(thing, actor: %{id: @actor_id, email: @actor_email}, tenant: @tenant)

      [{event, meta}] = InMemory.entries()

      assert meta == %{tenant: @tenant, resource: Thing, action: :destroy}
      event |> Jason.encode!() |> Jason.decode!() |> then(&assert_clean!(&1, forbidden()))
    end

    test "no tenant on the action is a nil tenant in meta" do
      Ash.create!(Ash.Changeset.for_create(Thing, :create, %{name: "harmless"}))

      assert [{_event, %{tenant: nil, resource: Thing, action: :create}}] = InMemory.entries()
    end
  end

  describe "the ashOpenLineageSnapshot facet" do
    # The snapshot envelope exists precisely so actor/tenant/data never leave
    # the host; its facet must reduce it to a digest fingerprint. The test
    # snapshot's authority map and inputs are stuffed with forbidden values so
    # a leak of any of them trips assert_clean!/2.
    test "carries only digest, purpose, input_count and definition_kinds" do
      snapshot = base_snapshot()

      facet = Event.snapshot_facet(snapshot)

      assert MapSet.new(Map.keys(facet)) ==
               MapSet.new([
                 "_producer",
                 "_schemaURL",
                 "digest",
                 "purpose",
                 "input_count",
                 "definition_kinds"
               ])

      assert facet["digest"] == snapshot.digest
      assert facet["purpose"] == "personal_week"
      assert facet["input_count"] == 1
      assert facet["definition_kinds"] == ["dmn"]

      facet |> Jason.encode!() |> Jason.decode!() |> then(&assert_clean!(&1, forbidden()))
      assert_clean!(facet, forbidden())
    end

    # Hostile atoms: purpose and definition kind are allow-listed precisely so
    # a data-bearing atom cannot ride Atom.to_string/1 onto the wire.
    test "raises on a data-bearing purpose atom and never emits it" do
      snapshot = %Snapshot{
        base_snapshot()
        | purpose: :"#{@tenant}",
          digest: String.duplicate("ef", 32)
      }

      assert_raise ArgumentError, ~r/invalid snapshot purpose/, fn ->
        Event.snapshot_facet(snapshot)
      end

      refute(Enum.any?(rescued_facets(snapshot), &(&1 =~ @tenant)))
    end

    test "raises on a data-bearing definition kind atom and never emits it" do
      leaky_definition = %Snapshot.Definition{
        kind: :"leak-#{@tenant}",
        key: "model",
        version: "1",
        content_hash: String.duplicate("cc", 32)
      }

      snapshot = %Snapshot{
        base_snapshot()
        | digest: String.duplicate("ef", 32),
          definitions: [leaky_definition]
      }

      assert_raise ArgumentError, ~r/invalid snapshot definition kind/, fn ->
        Event.snapshot_facet(snapshot)
      end

      refute(Enum.any?(rescued_facets(snapshot), &(&1 =~ @tenant)))
    end

    # The digest is a fingerprint: only a lowercase 64-hex SHA-256 may ride the
    # wire, so a data-bearing (or malformed, or uppercase, or short) binary
    # fails closed.
    test "raises on a digest that is not a lowercase 64-hex sha256" do
      for digest <- [
            "not-a-digest",
            String.upcase(String.duplicate("ef", 32)),
            String.duplicate("ef", 63),
            @actor_id <> " with data values " <> @tenant
          ] do
        snapshot = %Snapshot{base_snapshot() | digest: digest}

        assert_raise ArgumentError, ~r/invalid snapshot digest/, fn ->
          Event.snapshot_facet(snapshot)
        end
      end

      # nil is missing input for a digest-only facet, not a valid one
      assert_raise ArgumentError, ~r/invalid snapshot digest/, fn ->
        Event.snapshot_facet(%Snapshot{base_snapshot() | digest: nil})
      end
    end
  end

  # A minimal valid snapshot: the facet only reads digest, purpose, inputs
  # (count) and definitions (kinds), and the leak tests set the hostile fields
  # per case.
  defp base_snapshot do
    %Snapshot{
      id: "snap-1",
      purpose: :personal_week,
      effective_at: ~U[2026-11-05T00:00:00Z],
      knowledge_cutoff: ~U[2026-11-05T00:00:00Z],
      world: :real,
      authority: %{tenant: @tenant, actor_id: @actor_id, completeness: :full},
      inputs: [
        %Snapshot.Input{
          key: "tasks.mine",
          role: :plannable,
          status: :resolved,
          source: %{resource: "Task", id: @tenant, version_number: 1},
          content_hash: String.duplicate("aa", 32)
        }
      ],
      definitions: [
        %Snapshot.Definition{
          kind: :dmn,
          key: "canonical.planning_requirements",
          version: "1",
          content_hash: String.duplicate("cc", 32)
        }
      ],
      payload_hash: nil,
      digest: String.duplicate("ef", 32)
    }
  end

  # Belt-and-braces: capture whatever facet a rescued call could have built and
  # show none of it ever carried the hostile string. Map/struct serialized to
  # its inspect form so keys and values are both covered.
  defp rescued_facets(snapshot) do
    case try_snapshot_facet(snapshot) do
      {:ok, facet} -> [inspect(facet)]
      {:error, _} -> []
    end
  end

  defp try_snapshot_facet(snapshot) do
    Event.snapshot_facet(snapshot)
    |> then(&{:ok, &1})
  rescue
    error -> {:error, error}
  end

  defp forbidden, do: [@tenant, @actor_id, @actor_email]
end
