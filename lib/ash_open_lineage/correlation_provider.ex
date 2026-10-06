# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.CorrelationProvider do
  @moduledoc """
  Where run ids and nesting depth come from.

  A lineage run id is most useful when it *is* the host's correlation id: one
  lookup then joins every audit row, log line and lineage event for an
  operation. That is why this is a behaviour the host implements, not a UUID
  minted here.

  Configure per host:

      config :ash_open_lineage, correlation_provider: AshEnterprise.Platform.Correlation

  The canonical host implementation is `AshEnterprise.Platform.Correlation`
  (`id/0` + `depth/0`, process-dictionary scoped, started per request).

  ## The parent seam

  A depth above zero says "nested under some outer operation", which adds the
  `parent` run facet — but a depth alone does not name the parent. The parent's
  run id comes from an optional second provider:

      config :ash_open_lineage, parent_id_provider: MyApp.ParentRunId

  ...where `MyApp.ParentRunId.parent_id/0` returns the enclosing run's id or
  `nil`. A typical implementation reads the correlation record the host keeps
  when it starts a wrapping job. Until one is configured, a non-zero depth
  produces **no parent facet** — the nesting is known, the parent's id is not,
  and the facet is omitted rather than fabricated. The id and the depth stay
  consistent either way, because both come from the same provider.

  ## Default

  `AshOpenLineage.CorrelationProvider.Default` mints a fresh UUID per call and
  always reports depth 0: standalone, un-nested runs. Correct for processes
  with no correlation context, and the reason an unconfigured host still
  produces valid events.
  """

  @callback id() :: String.t()
  @callback depth() :: non_neg_integer()
end

defmodule AshOpenLineage.CorrelationProvider.Default do
  @moduledoc """
  The default `AshOpenLineage.CorrelationProvider`: a fresh
  `Ash.UUID.generate/0` per `id/0` call, depth always 0.

  Every event built without an explicit `:run_id` and without a configured
  provider is its own run — standalone and honest about it.
  """

  @behaviour AshOpenLineage.CorrelationProvider

  @impl true
  def id, do: Ash.UUID.generate()

  @impl true
  def depth, do: 0
end
