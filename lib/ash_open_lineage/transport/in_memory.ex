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

  Or globally in `config/dev.exs` for eyeballing events without a catalogue:

      config :ash_open_lineage, transport: AshOpenLineage.Transport.InMemory
  """

  use Agent
  @behaviour AshOpenLineage.Transport

  @doc "Starts the store. `:initial` seeds prior events; tests use `start_supervised!/1`."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> Keyword.get(opts, :initial, []) end, name: __MODULE__)
  end

  @impl true
  def send(event) do
    Agent.update(__MODULE__, &[event | &1])
    :ok
  end

  @doc "All events sent so far, oldest first. `[]` when not running — never a raise."
  @spec events() :: [map()]
  def events do
    case Process.whereis(__MODULE__) do
      nil -> []
      _agent -> Agent.get(__MODULE__, &Enum.reverse/1)
    end
  end

  @doc "Discards collected events (between test cases)."
  @spec clear() :: :ok
  def clear, do: Agent.update(__MODULE__, fn _ -> [] end)
end
