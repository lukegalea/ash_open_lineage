# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Transformer do
  @moduledoc """
  Installs `AshOpenLineage.Notifier` on the resource.

  Notifiers live in the DSL's persisted `:notifiers` list (the same place
  `use Ash.Resource, notifiers: [...]` writes to), so the host never declares
  the notifier itself, and one they declared separately keeps working — we
  append and deduplicate rather than replace.
  """

  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    notifiers =
      dsl_state
      |> Spark.Dsl.Transformer.get_persisted(:notifiers, [])
      |> Enum.uniq()
      |> Kernel.++([AshOpenLineage.Notifier])
      |> Enum.uniq()

    {:ok, Spark.Dsl.Transformer.persist(dsl_state, :notifiers, notifiers)}
  end
end
