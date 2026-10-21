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

  ## Host metadata: the optional `send/2`

  A transport may also export `send(event, meta)`. When it does, the library
  calls `send/2` instead of `send/1` (see `dispatch/3`), passing a `t:meta/0`
  map of in-process host context alongside the event. The notifier fills it
  with the action's `:tenant` (the changeset's tenant, or `nil`), `:resource`
  and `:action`; `AshOpenLineage.emit/2` and `AshOpenLineage.fail/3` pass
  whatever the caller gives as their `:meta` option.

  The use case is a host transport that persists events to its own database
  and needs to scope the stored rows — by tenant, typically. The library never
  serialises `meta`, never copies any of it into the event, and the shipped
  `AshOpenLineage.Transport.Req` ignores it. The leak rule is about the event,
  and it still holds: what a host transport does with `meta` (for example,
  writing a tenant column next to the stored event) stays on the host's side
  of the line.
  """

  @typedoc """
  In-process host context handed to `send/2`. Never part of the event.

  The notifier sets `:tenant`, `:resource` and `:action`; `emit/2`/`fail/3`
  pass their `:meta` option through as given.
  """
  @type meta :: %{
          optional(:tenant) => term(),
          optional(:resource) => module(),
          optional(:action) => atom(),
          optional(atom()) => term()
        }

  @callback send(event :: map()) :: :ok | {:error, term()}
  @callback send(event :: map(), meta :: meta()) :: :ok | {:error, term()}

  @optional_callbacks send: 2

  @doc """
  Sends `event` through `transport`: `transport.send(event, meta)` when the
  module exports `send/2`, otherwise `transport.send(event)` and `meta` is
  dropped.

  The module is loaded first (`Code.ensure_loaded?/1`) so a lazily-loaded
  transport in dev or test is not mistaken for a `send/1`-only one.
  """
  @spec dispatch(module(), map(), meta()) :: :ok | {:error, term()}
  def dispatch(transport, event, meta) when is_atom(transport) and is_map(meta) do
    if Code.ensure_loaded?(transport) and function_exported?(transport, :send, 2) do
      transport.send(event, meta)
    else
      transport.send(event)
    end
  end
end
