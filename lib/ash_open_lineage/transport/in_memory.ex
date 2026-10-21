# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Transport.InMemory do
  @moduledoc """
  Stores every sent event in an Agent — the transport for tests and
  development.

      # in a test
      start_supervised!(AshOpenLineage.Transport.InMemory)

      Ash.create!(Ash.Changeset.for_create(Ticket, :create, %{...}), notify?: true)

      assert [%{"eventType" => "COMPLETE"}] = AshOpenLineage.Transport.InMemory.events()

  It implements `send/2` as well, so the host metadata handed to transports
  (see `AshOpenLineage.Transport`) is kept next to each event: `entries/0`
  returns `{event, meta}` pairs. `events/0` returns the events alone.

  Or globally in `config/dev.exs` for eyeballing events without a catalogue:

      config :ash_open_lineage, transport: AshOpenLineage.Transport.InMemory
  """

  use Agent
  @behaviour AshOpenLineage.Transport

  @doc """
  Starts the store. `:initial` seeds prior events (each stored with empty
  meta); tests use `start_supervised!/1`.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    initial =
      opts
      |> Keyword.get(:initial, [])
      |> Enum.map(&{&1, %{}})

    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  @impl true
  # Qualified: an unqualified send/2 here would clash with Kernel.send/2.
  def send(event), do: __MODULE__.send(event, %{})

  @impl true
  def send(event, meta) do
    Agent.update(__MODULE__, &[{event, meta} | &1])
    :ok
  end

  @doc "All events sent so far, oldest first. `[]` when not running — never a raise."
  @spec events() :: [map()]
  def events, do: Enum.map(entries(), fn {event, _meta} -> event end)

  @doc """
  All `{event, meta}` pairs sent so far, oldest first — `meta` is the host
  metadata the sender passed (`%{}` for a plain `send/1`). `[]` when not
  running.
  """
  @spec entries() :: [{map(), AshOpenLineage.Transport.meta()}]
  def entries do
    case Process.whereis(__MODULE__) do
      nil -> []
      _agent -> Agent.get(__MODULE__, &Enum.reverse/1)
    end
  end

  @doc "Discards collected events (between test cases)."
  @spec clear() :: :ok
  def clear, do: Agent.update(__MODULE__, fn _ -> [] end)
end
