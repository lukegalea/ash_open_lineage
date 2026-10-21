# AshOpenLineage

<!-- SPDX-FileCopyrightText: 2026 Luke Galea -->
<!-- SPDX-License-Identifier: MIT -->

An Elixir OpenLineage emitter: a Spark extension + `Ash.Notifier` that
gives every Ash resource OpenLineage provenance, plus a small API for jobs that
never touch a resource.

Spec **2-0-2** RunEvents, emitted to Marquez / DataHub / Atlan / anything that
speaks the OpenLineage HTTP contract. Contracted by ADR 0012
(`../ash_enterprise/docs/adr/0012-openlineage-and-marquez.md`).

## The leak rule

**Every facet this library emits carries structural names only** — job,
resource, action and table names. Never actor identities, never tenant ids,
never filter or argument values. Lineage answers *what moved*; who moved it and
for whom lives in the host's audit trail. The test suite enforces this by
injecting an actor and a tenant into a run and asserting neither string appears
anywhere in the event — and it proves the assertion bites by failing it against
a deliberately-leaking map first.

## Quickstart

```elixir
# mix.exs
{:ash_open_lineage, github: "lukegalea/ash_open_lineage"}
```

Attach the extension to a resource:

```elixir
defmodule MyApp.Support.Ticket do
  use Ash.Resource,
    domain: MyApp.Support,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOpenLineage.Extension]

  postgres do
    repo MyApp.Repo
    table "tickets"
  end

  lineage do
    transport AshOpenLineage.Transport.Req
  end

  # ...
end
```

Configure the host seams:

```elixir
config :ash_open_lineage,
  # run ids are derived from this (see AshOpenLineage.CorrelationProvider)
  correlation_provider: AshEnterprise.Platform.Correlation,
  # optional: module exporting parent_id/0, for the parent run facet
  parent_id_provider: MyApp.ParentRunId,
  # for AshOpenLineage.Transport.Req
  http_base_url: "http://localhost:5000"
```

Resource actions now emit one `COMPLETE` RunEvent per successful
create/update/destroy. On **ash ≥ 3.34** notifications dispatch automatically
after a successful action; on earlier 3.x releases Ash requires the per-call
opt-in `notify?: true` (`Ash.create!(changeset, notify?: true)`).

Emit for non-Ash jobs (the "hole rule": an ingestion wrapper that runs a Meltano
tap outside Ash must still fill the graph):

```elixir
job = %{
  namespace: "ingestion",
  name: "gmail.sync",
  inputs: ["gmail"],
  outputs: [%{namespace: "warehouse", name: "raw.gmail_messages"}]
}

AshOpenLineage.emit(job, event_type: :start, run_id: run_id)
# ... run the tap ...
AshOpenLineage.emit(job, event_type: :complete, run_id: run_id)
# or, when it goes wrong:
AshOpenLineage.fail(job, "tap crashed: Google API 410 gone", run_id: run_id)
```

Failing taps emit `FAIL`, not silence — silence is how a broken pipeline
disappears from the graph while still costing money.

## Shape of an event

```json
{
  "eventTime": "2026-01-01T00:00:00Z",
  "eventType": "COMPLETE",
  "producer": "https://github.com/lukegalea/ash_open_lineage",
  "schemaURL": "https://openlineage.io/spec/2-0-2/OpenLineage.json#/$defs/RunEvent",
  "inputs": [],
  "outputs": [{"namespace": "catalog", "name": "tickets"}],
  "job": {"namespace": "support", "name": "ticket.create"},
  "run": {
    "runId": "9b2f4c1e-7d3a-4e58-b6c0-2a1f8e5d4c37",
    "facets": {
      "parent": {"_producer": "...", "_schemaURL": "...", "run": {"runId": "..."}},
      "ashOpenLineageProducer": {
        "_producer": "...", "_schemaURL": "...",
        "producer_name": "support.ticket.create",
        "correlationId": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "depth": 1
      }
    }
  }
}
```

* Job name is `"{resource_singular}.{action_name}"`; the namespace defaults to
  the domain module's last segment, underscored — override with `namespace` in
  the `lineage` section when your catalogue needs to match other producers.
* The dataset comes from the resource's `postgres do table end` declaration
  (schema-qualified when a schema is set). A resource with no postgres table
  contributes **no dataset** rather than a guess.
* `runId` is derived from the host's correlation id and the job —
  `sha256("{correlation}/{namespace}/{job}")` formatted UUID-shaped — so each
  job gets its own run within one correlation, and repeat invocations of the
  same job in that correlation share it. The correlation id itself travels in
  the `ashOpenLineageProducer` facet as `correlationId` (with `depth`). That
  field joins a lineage event to the host's audit trail (and to its logs, if
  the host logs the same id) only when the configured provider returns a
  stable id for the whole operation, as a per-request provider does. The
  default provider mints a fresh UUID on every call, so its `correlationId`
  matches nothing else, not even the id the `runId` was derived from. The
  `parent` facet appears only when depth is above zero *and*
  `:parent_id_provider` returns an id (the example above shows depth 1 with a
  provider configured); otherwise it is omitted.
* START/FAIL for resource actions are deliberately out of scope (ADR 0012): a
  notifier can only state what already happened. The host emits its own START
  via `AshOpenLineage.emit/2` before a call when it wants one.

## Transports

* `AshOpenLineage.Transport.Req` — `POST {http_base_url}/api/v1/lineage`.
  Errors return as `{:error, term}`, never raise.
* `AshOpenLineage.Transport.InMemory` — Agent-backed store with `events/0`,
  for tests and dev (`start_supervised!(AshOpenLineage.Transport.InMemory)`).
  `entries/0` returns `{event, meta}` pairs, for tests that check host
  metadata.

Anything implementing `send(event :: map()) :: :ok | {:error, term()}` works
with the `transport` DSL option.

### Host metadata (`send/2`)

A transport may also implement the optional callback
`send(event, meta) :: :ok | {:error, term()}`. When it does, the library calls
it instead of `send/1` (`AshOpenLineage.Transport.dispatch/3` makes the
choice), and `meta` carries host context the event never does:

* from the notifier: `%{tenant: tenant, resource: resource, action: action_name}`,
  where `tenant` is the action's changeset tenant, or `nil`;
* from `emit/2` and `fail/3`: whatever map you pass as the `:meta` option
  (default `%{}`).

This is for a host transport that stores events in its own database and needs
to scope the rows, typically by tenant:

```elixir
defmodule MyApp.Lineage.StoreTransport do
  @behaviour AshOpenLineage.Transport

  @impl true
  # qualified: an unqualified send/2 would clash with Kernel.send/2
  def send(event), do: __MODULE__.send(event, %{})

  @impl true
  def send(event, meta) do
    MyApp.Lineage.store_event(event, tenant: meta[:tenant])
  end
end

AshOpenLineage.emit(job, run_id: run_id, meta: %{tenant: tenant})
```

`meta` stays in-process. The library never serialises it and never copies any
of it into the event, and `AshOpenLineage.Transport.Req` ignores it. The leak
rule is about the event and still holds; the leak test checks that a tenant
reaches `meta` while the event built for the same action stays clean.

### Run ids for your own jobs

`AshOpenLineage.run_id(correlation_id, namespace, job_name)` is the
derivation the notifier uses for resource jobs. A host emitting its own jobs
inside one correlation can pass it as `:run_id`, so each job gets its own
stable run just as resource jobs do:

```elixir
run_id = AshOpenLineage.run_id(correlation_id, "ingestion", "gmail.sync")
AshOpenLineage.emit(job, event_type: :start, run_id: run_id)
```

## Testing your own integration

```elixir
setup do
  start_supervised!(AshOpenLineage.Transport.InMemory)
  :ok
end

test "creating a ticket is traceable" do
  Ash.create!(Ash.Changeset.for_create(Ticket, :create, %{...}))
  assert [%{"eventType" => "COMPLETE", "job" => %{"name" => "ticket.create"}}] =
           AshOpenLineage.Transport.InMemory.events()
end
```

## Spec fixture provenance

`priv/openlineage/s/run-event.json` is the OpenLineage **2-0-2** schema,
vendored **verbatim** from `https://openlineage.io/spec/2-0-2/OpenLineage.json`
— the consolidated model whose `$defs/RunEvent` defines the RunEvent. (The
historical `.../spec/2-0-2/OpenLineageRunEvent.json` URL now 404s; the
consolidated file is where that content lives, and it is self-contained — all
`$ref`s are local.) The conformance suite validates built events against it with
`ex_json_schema`. `priv/openlineage/facets/ash_open_lineage_producer_facet.json`
is this library's own facet schema, shipped so the facet's `_schemaURL` points
at something real.

## Status

`0.1.0`. Developed against ash 3.34 / Spark 2.7.6 (constraint `{:ash, "~> 3.0"}`).
See `usage-rules.md` for the host-integration rules, including the hole rule and
the leak rule.

MIT licensed. SPDX headers in every source file.
