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
  """

  use ExUnit.Case, async: true

  import AshOpenLineage.TestSupport.LeakCheck, only: [assert_clean!: 2]

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

  defp forbidden, do: [@tenant, @actor_id, @actor_email]
end
