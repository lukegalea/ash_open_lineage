# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Transport do
  @moduledoc """
  The behaviour that carries a built RunEvent to a lineage catalogue.

  `send/1` receives the event as a string-keyed map (already shaped for
  `Jason.encode!/1`) and returns `:ok` or `{:error, term()}` — it should not
  raise. Shipped implementations:

    * `AshOpenLineage.Transport.Req` — POSTs to an OpenLineage-compatible HTTP
      endpoint (Marquez, DataHub, Atlan, ...), the default for `AshOpenLineage.emit/2`.
    * `AshOpenLineage.Transport.InMemory` — collects events in an Agent for
      tests and development.

  A host transport only has to obey the return contract; the notifier logs
  `{:error, term}` results and moves on.
  """

  @callback send(event :: map()) :: :ok | {:error, term()}
end
