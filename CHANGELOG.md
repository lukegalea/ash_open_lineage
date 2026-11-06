<!-- SPDX-FileCopyrightText: 2026 Luke Galea -->
<!-- SPDX-License-Identifier: MIT -->

# Changelog

## Unreleased

Requires Elixir 1.20 or later.

## 0.2.1 — Vocabulary reconciliation

Reconciled the shared snapshot vocabulary to the #147 extraction terms
(owner decision 2026-11-05): dotted purposes, `world` becomes
`:operational | :scenario`, input `status` becomes
`:value | :unresolved | :invalid | :missing_citation`. Definition kinds are
unchanged. The cross-host golden digest changed accordingly (envelope
content changed); the old constant is retired.

## 0.2.0 — Snapshot value contract

- **Added** `AshOpenLineage.Snapshot` — a pure value struct (plus nested
  `Snapshot.Input` / `Snapshot.Definition` structs) describing the knowledge
  a solve or check job consumed: purpose, effective/knowledge cutoffs, world,
  authority, input and definition references with content hashes, payload
  hash, and a lowercase hex SHA-256 `digest` over the canonical JSON encoding
  (`AshOpenLineage.Snapshot.CanonicalJSON.encode/1`, RFC 8785; `put_digest/1`
  computes it). No Ash dependency; the envelope carries references and hashes
  only — never actor, tenant, or data values.
- **Added** the `ashOpenLineageSnapshot` run facet
  (`AshOpenLineage.Event.snapshot_facet/2`): digest, purpose, input count, and
  distinct definition kinds — digest/structural values only. Schema vendored at
  `priv/openlineage/facets/ash_open_lineage_snapshot_facet.json`; covered by
  the leak test like every other facet.
