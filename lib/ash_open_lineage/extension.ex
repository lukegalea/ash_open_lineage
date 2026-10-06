# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Extension do
  @moduledoc """
  Adds OpenLineage emission to an Ash resource.

  Add it to the resource's `extensions` list and configure the `lineage` section:

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

        # ... attributes, actions ...
      end

  The extension installs `AshOpenLineage.Notifier` on the resource — there is
  nothing to add to `notifiers:`. One `COMPLETE` RunEvent is emitted per
  successful create/update/destroy (see `emit_on`), through the configured
  transport. On ash ≥ 3.34 notifications dispatch automatically after
  successful actions; on earlier 3.x releases pass `notify?: true` per call.
  """

  use Spark.Dsl.Extension,
    sections: [AshOpenLineage.Dsl.lineage()],
    transformers: [AshOpenLineage.Transformer]
end
