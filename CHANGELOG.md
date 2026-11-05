<!-- SPDX-FileCopyrightText: 2026 Luke Galea -->
<!-- SPDX-License-Identifier: MIT -->

# Changelog

## Unreleased — Snapshot value contract

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
