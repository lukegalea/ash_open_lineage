# AshOpenLineage

<!-- SPDX-FileCopyrightText: 2026 Luke Galea -->
<!-- SPDX-License-Identifier: MIT -->

The **first Elixir OpenLineage emitter**: a Spark extension + `Ash.Notifier` that
gives every Ash resource OpenLineage provenance, plus a small API for jobs that
never touch a resource.

Spec **2-0-2** RunEvents, emitted to Marquez / DataHub / Atlan / anything that
speaks the OpenLineage HTTP contract. Contracted by ADR 0012
(`../ash_enterprise/docs/adr/0012-openlineage-and-marquez.md`) after finding
zero on hex.

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
  # run ids come from here (see AshOpenLineage.CorrelationProvider)
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
    "runId": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "facets": {
      "parent": {"_producer": "...", "_schemaURL": "...", "run": {"runId": "..."}},
      "ashOpenLineageProducer": {
        "_producer": "...", "_schemaURL": "...",
        "producer_name": "support.ticket.create"
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
* `runId` is the host's correlation id — one lookup joins the audit trail, the
  logs and the lineage graph. Depth above zero adds the `parent` facet; the
  parent's id comes from `:parent_id_provider` or the facet is omitted.
* START/FAIL for resource actions are deliberately out of scope (ADR 0012): a
  notifier can only state what already happened. The host emits its own START
  via `AshOpenLineage.emit/2` before a call when it wants one.

## Transports

* `AshOpenLineage.Transport.Req` — `POST {http_base_url}/api/v1/lineage`.
  Errors return as `{:error, term}`, never raise.
* `AshOpenLineage.Transport.InMemory` — Agent-backed store with `events/0`,
  for tests and dev (`start_supervised!(AshOpenLineage.Transport.InMemory)`).

Anything implementing `send(event :: map()) :: :ok | {:error, term()}` works
with the `transport` DSL option.

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
