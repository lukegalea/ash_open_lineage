# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Event do
  @moduledoc """
  Pure builders for OpenLineage `RunEvent` maps, shaped for spec **2-0-2**.

  Everything here is a total function over its options: no transport, no
  application config, no clock beyond the `:event_time` default. That is what
  makes the golden-fixture tests and the vendored-schema conformance test able
  to pin this module's output byte for byte. The notifier and `AshOpenLineage.emit/2`
  are thin option-gatherers around this module.

  ## Where each field comes from

    * `eventTime` — `:event_time` option, or `DateTime.utc_now/0`.
    * `eventType` — `:event_type` (`:start | :complete | :fail`), uppercased.
    * `producer` / `schemaURL` — required by the 2-0-2 consolidated spec's
      `BaseEvent`; the producer URI travels in `:producer` and the schema URL is
      pinned to the vendored spec's `RunEvent` definition.
    * `run.runId` — the caller's `:run_id`, or a fresh id from the configured
      correlation provider. Callers that care (the notifier) always pass one so
      START/COMPLETE/FAIL for the same work share an id.
    * `run.facets` — the `parent` facet when `:parent_run_id` is present (with
      the optional v1.52 `root` sub-object when `:root` is given), the custom
      `ashOpenLineageProducer` facet always, and the `error` facet for `:fail`.
  """

  @producer "https://github.com/lukegalea/ash_open_lineage"
  @run_event_schema_url "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/RunEvent"

  # The 2-0-2 consolidated spec folds facets into `#/$defs/BaseFacet` (all facets
  # are `BaseFacet` + extras); the historical per-facet URLs it replaced 404, so
  # this is the honest pointer for every built-in facet we emit.
  @base_facet_schema_url "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/BaseFacet"

  @producer_facet_name "ashOpenLineageProducer"

  # The facet schema ships in this repo; the URL is honest as soon as the
  # repository is public at the same path.
  @producer_facet_schema_url "https://github.com/lukegalea/ash_open_lineage/blob/main/priv/openlineage/facets/ash_open_lineage_producer_facet.json"

  @snapshot_facet_name "ashOpenLineageSnapshot"

  @snapshot_facet_schema_url "https://github.com/lukegalea/ash_open_lineage/blob/main/priv/openlineage/facets/ash_open_lineage_snapshot_facet.json"

  # The leak boundary: a facet string must never be caller-supplied data. An
  # atom like `:"tenant-acme-corp-42"` passed as a purpose or definition kind
  # would ride Atom.to_string/1 straight onto the wire, so the builder is total
  # over NO atoms — every purpose/kind must be on these lists. Extending a list
  # is a deliberate first-party edit (plus a schema/leak-test touch), never a
  # call-site option.
  @purposes [:personal_week]

  @definition_kinds [:dmn, :bpmn, :mzn, :validator]

  @type event_type :: :start | :complete | :fail

  @type dataset_descriptor ::
          String.t()
          | {String.t(), String.t()}
          | %{:name => String.t(), optional(:namespace) => String.t(), optional(:facets) => map()}

  @event_types [:start, :complete, :fail]

  @doc "The facet key under which this library's custom producer facet is emitted."
  @spec producer_facet_name() :: String.t()
  def producer_facet_name, do: @producer_facet_name

  @doc "The facet key under which this library's snapshot digest facet is emitted."
  @spec snapshot_facet_name() :: String.t()
  def snapshot_facet_name, do: @snapshot_facet_name

  @doc """
  Builds the `ashOpenLineageSnapshot` run facet from an
  `t:AshOpenLineage.Snapshot.t/0`.

  Digest and structural values only: the snapshot's digest, its purpose atom
  (as a snake_case string), the input count, and the distinct definition
  kinds. It never carries the snapshot's authority map (tenant/actor), input
  sources, or any data values — the envelope is references and hashes, and
  this facet reduces it to a digest fingerprint. The leak test enforces the
  boundary.

  Purposes and definition kinds are allow-listed (`@purposes`,
  `@definition_kinds`), and the digest must be a lowercase 64-hex SHA-256
  (`"^[0-9a-f]{64}$"`); any other atom or binary — one that could smuggle a
  data-bearing value onto the wire — raises `ArgumentError`. Validation only:
  deriving the digest stays `AshOpenLineage.Snapshot.put_digest/1`'s job.
  Extending a list is a deliberate first-party edit, not a call-site option.
  """
  @spec snapshot_facet(AshOpenLineage.Snapshot.t(), String.t()) :: map()
  def snapshot_facet(%AshOpenLineage.Snapshot{} = snapshot, producer \\ @producer) do
    %{
      "_producer" => producer,
      "_schemaURL" => @snapshot_facet_schema_url,
      "digest" => digest_string!(snapshot.digest),
      "purpose" => purpose_string!(snapshot.purpose),
      "input_count" => length(snapshot.inputs),
      "definition_kinds" =>
        snapshot.definitions |> Enum.map(&kind_string!(&1.kind)) |> Enum.uniq()
    }
  end

  # A digest is a fingerprint, so the facet string must be exactly a lowercase
  # hex SHA-256 — never a caller-chosen binary. A nil digest is missing input
  # for a digest-only facet (run Snapshot.put_digest/1 first), not a valid one.
  defp digest_string!(digest) when is_binary(digest) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, digest) do
      digest
    else
      raise ArgumentError,
            "invalid snapshot digest #{inspect(digest)} — the ashOpenLineageSnapshot " <>
              "facet requires a lowercase 64-hex SHA-256; compute it with " <>
              "AshOpenLineage.Snapshot.put_digest/1"
    end
  end

  defp digest_string!(other) do
    raise ArgumentError,
          "invalid snapshot digest #{inspect(other)} — the ashOpenLineageSnapshot " <>
            "facet requires a lowercase 64-hex SHA-256; compute it with " <>
            "AshOpenLineage.Snapshot.put_digest/1"
  end

  defp purpose_string!(purpose) when purpose in @purposes, do: Atom.to_string(purpose)

  defp purpose_string!(other) do
    raise ArgumentError,
          "invalid snapshot purpose #{inspect(other)} — the ashOpenLineageSnapshot " <>
            "facet only allows #{inspect(@purposes)}"
  end

  defp kind_string!(kind) when kind in @definition_kinds, do: Atom.to_string(kind)

  defp kind_string!(other) do
    raise ArgumentError,
          "invalid snapshot definition kind #{inspect(other)} — the ashOpenLineageSnapshot " <>
            "facet only allows #{inspect(@definition_kinds)}"
  end

  @doc """
  Builds one RunEvent as a string-keyed map, ready for `Jason.encode!/1` or any
  transport.

  ## Options

    * `:event_type` (required) — `:start`, `:complete` or `:fail`.
    * `:event_time` — `%DateTime{}` or ISO8601 binary; defaults to now (UTC).
    * `:job_namespace`, `:job_name` (required) — the OpenLineage job.
    * `:inputs`, `:outputs` — lists of `t:dataset_descriptor/0`; a bare string is
      placed in the job's namespace.
    * `:run_id` — defaults to a fresh id from the correlation provider.
    * `:parent_run_id` — emits the `parent` run facet when present.
    * `:root` — optional `%{namespace: _, name: _, run_id: _}` adding the v1.52
      `root` sub-object to the parent facet.
    * `:producer` — producer URI override; defaults to this library's URI.
    * `:producer_name` (required) — value of the `ashOpenLineageProducer` facet.
      **Structural names only** (job, resource, action, table). Never actor,
      tenant, or data values.
    * `:error_message` — required for `event_type: :fail`; lands in the `error`
      run facet's `errorMessage`.
  """
  @spec run_event(keyword()) :: %{optional(String.t()) => term()}
  def run_event(opts) do
    event_type = event_type!(Keyword.fetch!(opts, :event_type))
    producer = Keyword.get(opts, :producer, @producer)

    event = %{
      "eventTime" => event_time(opts[:event_time]),
      "eventType" => String.upcase(Atom.to_string(event_type)),
      "producer" => producer(opts),
      "schemaURL" => @run_event_schema_url,
      "inputs" => datasets(opts[:inputs], opts),
      "outputs" => datasets(opts[:outputs], opts),
      "job" => job(opts),
      "run" => %{
        "runId" => run_id(opts),
        "facets" => run_facets(opts, producer(opts))
      }
    }

    if event_type == :fail do
      put_in(event, ["run", "facets", "error"], error_facet(opts, producer))
    else
      event
    end
  end

  # --- parts -------------------------------------------------------------------

  defp event_type!(type) when type in @event_types, do: type

  defp event_type!(other) do
    raise ArgumentError,
          "invalid :event_type #{inspect(other)} — expected one of #{inspect(@event_types)}"
  end

  # `Keyword.get/3` returns a stored nil, so an explicit nil override (as the
  # public API builds) must read as unset: resolve with case, not defaults.
  defp producer(opts) do
    case Keyword.get(opts, :producer) do
      nil -> @producer
      producer -> producer
    end
  end

  defp run_id(opts) do
    case Keyword.get(opts, :run_id) do
      nil -> AshOpenLineage.correlation_provider().id()
      run_id -> run_id
    end
  end

  defp event_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp event_time(time) when is_binary(time), do: time
  defp event_time(nil), do: DateTime.to_iso8601(DateTime.utc_now())

  defp job(opts) do
    %{
      "namespace" => Keyword.fetch!(opts, :job_namespace),
      "name" => Keyword.fetch!(opts, :job_name)
    }
  end

  defp run_facets(opts, producer) do
    %{}
    |> maybe_put("parent", parent_facet(opts[:parent_run_id], opts[:root], producer))
    |> Map.put(@producer_facet_name, producer_facet(opts, producer))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Spec-wise the parent facet's minimal valid form is `run.runId`; the parent's
  # job name is not known through either path this library offers (a depth
  # counter, or an explicit id), so it is never fabricated here.
  defp parent_facet(nil, _root, _producer), do: nil

  defp parent_facet(parent_run_id, root, producer) do
    %{
      "_producer" => producer,
      "_schemaURL" => @base_facet_schema_url,
      "run" => %{"runId" => parent_run_id}
    }
    |> maybe_put("root", root_subobject(root))
  end

  defp root_subobject(nil), do: nil

  defp root_subobject(%{namespace: ns, name: name, run_id: run_id}) do
    %{"job" => %{"namespace" => ns, "name" => name}, "run" => %{"runId" => run_id}}
  end

  # Structural names only — plus the correlation id and depth, which are the
  # host's own correlation metadata (an opaque id, never a value, actor or
  # tenant). The runId is *derived* from the correlation id, so this facet is
  # what makes "lineage run for this audit entry" a direct lookup again after
  # runIds became per-(correlation, job): the audit log's
  # metadata["correlation_id"] matches the facet's correlationId exactly.
  # If this facet ever grows a field derived from actor, tenant, or argument
  # values, the leak test must be the thing that catches it.
  defp producer_facet(opts, producer) do
    %{
      "_producer" => producer,
      "_schemaURL" => @producer_facet_schema_url,
      "producer_name" => Keyword.fetch!(opts, :producer_name)
    }
    |> maybe_put("correlationId", opts[:correlation_id])
    |> maybe_put("depth", opts[:correlation_depth])
  end

  defp error_facet(opts, producer) do
    %{
      "_producer" => producer,
      "_schemaURL" => @base_facet_schema_url,
      "errorMessage" => Keyword.fetch!(opts, :error_message)
    }
  end

  defp datasets(nil, _opts), do: []
  defp datasets(list, opts) when is_list(list), do: Enum.map(list, &dataset(&1, opts))

  defp dataset(name, opts) when is_binary(name) do
    %{"namespace" => Keyword.fetch!(opts, :job_namespace), "name" => name}
  end

  defp dataset({namespace, name}, _opts) when is_binary(namespace) and is_binary(name) do
    %{"namespace" => namespace, "name" => name}
  end

  defp dataset(%{name: name} = descriptor, opts) do
    base = %{
      "namespace" => Map.get(descriptor, :namespace) || Keyword.fetch!(opts, :job_namespace),
      "name" => name
    }

    case Map.get(descriptor, :facets) do
      nil -> base
      facets -> Map.put(base, "facets", stringify_keys(facets))
    end
  end

  # Host-side descriptors arrive string-keyed (JSON-adjacent); accept both.
  defp dataset(%{"name" => name} = descriptor, opts) do
    dataset(%{name: name, namespace: descriptor["namespace"], facets: descriptor["facets"]}, opts)
  end

  defp stringify_keys(facets) do
    Map.new(facets, fn {key, value} -> {to_string(key), value} end)
  end
end
