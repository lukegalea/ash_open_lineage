# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Test.Repo do
  @moduledoc """
  A real `Ecto.Repo` module so resources declaring `postgres do table end`
  compile. Never started, never connected to — only its existence and the
  table *declarations* are exercised, since dataset derivation reads the DSL,
  not the database.
  """

  use Ecto.Repo, otp_app: :ash_open_lineage, adapter: Ecto.Adapters.Postgres
end

defmodule AshOpenLineage.Test.Catalog do
  @moduledoc "The fixture domain. Its last segment, `catalog`, is the derived namespace."

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshOpenLineage.Test.Thing
    resource AshOpenLineage.Test.Selective
    resource AshOpenLineage.Test.PostgresThing
    resource AshOpenLineage.Test.SchemaedThing
  end
end

defmodule AshOpenLineage.Test.Thing do
  @moduledoc "ETS-backed resource with default lineage settings."

  use Ash.Resource,
    domain: AshOpenLineage.Test.Catalog,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOpenLineage.Extension]

  ets do
    private? true
  end

  # Context multitenancy so the leak test can flow a tenant value through the
  # changeset without a tenant attribute — exactly the path a leaking facet
  # would have to resist.
  multitenancy do
    strategy :context
    global? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read, :update, :destroy]
  end

  lineage do
    transport(AshOpenLineage.Transport.InMemory)
  end
end

defmodule AshOpenLineage.Test.Selective do
  @moduledoc "Exercises the `producer`, `namespace` and `emit_on` options."

  use Ash.Resource,
    domain: AshOpenLineage.Test.Catalog,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshOpenLineage.Extension]

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :update]
  end

  lineage do
    transport(AshOpenLineage.Transport.InMemory)
    producer("https://example.com/selective-producer")
    namespace "selective_ns"
    emit_on([:create])
  end
end

defmodule AshOpenLineage.Test.PostgresThing do
  @moduledoc "Declares a plain postgres table; never queried. Pins dataset derivation."

  use Ash.Resource,
    domain: AshOpenLineage.Test.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOpenLineage.Extension]

  postgres do
    repo(AshOpenLineage.Test.Repo)
    table "ol_test_things"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read, :update, :destroy]
  end

  lineage do
    transport(AshOpenLineage.Transport.InMemory)
  end
end

defmodule AshOpenLineage.Test.SchemaedThing do
  @moduledoc "Declares a schema-qualified postgres table. Pins the `schema.table` name."

  use Ash.Resource,
    domain: AshOpenLineage.Test.Catalog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOpenLineage.Extension]

  postgres do
    repo(AshOpenLineage.Test.Repo)
    table "ol_schemaed_things"
    schema("ol_staging")
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    default_accept :*
    defaults [:create, :read, :update, :destroy]
  end

  lineage do
    transport(AshOpenLineage.Transport.InMemory)
  end
end

defmodule AshOpenLineage.Test.Correlation do
  @moduledoc """
  Stand-in for a host correlation provider: fixed id, depth 2 — deep enough to
  exercise the parent-facet path.
  """

  @behaviour AshOpenLineage.CorrelationProvider

  @impl true
  def id, do: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

  @impl true
  def depth, do: 2
end

defmodule AshOpenLineage.Test.ParentId do
  @moduledoc "Stand-in for the optional `:parent_id_provider` env."

  def parent_id, do: "99999999-8888-4777-8666-555555555555"
end
