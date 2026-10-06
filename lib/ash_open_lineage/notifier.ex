# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.Notifier do
  @moduledoc """
  The `Ash.Notifier` the `lineage` extension installs on a resource.

  On each successful action notification whose type is in the resource's
  `emit_on`, it builds one spec 2-0-2 RunEvent with `eventType: "COMPLETE"` and
  hands it to the configured transport.

  ## Why COMPLETE only

  Ash notifiers fire after a successful, authorized action has been applied —
  so COMPLETE is the one event type a notifier can state truthfully. START and
  FAIL describe *intentions*, which belong to whoever drives the work (ADR
  0012's framing). For resource actions the host emits START itself before the
  call if it wants one; for non-Ash jobs `AshOpenLineage.emit/2` and
  `AshOpenLineage.fail/2` cover the pair.

  ## runId and depth

  The run id is derived deterministically from the correlation id *and the
  job* — one stable run per (correlation, job) pair. Reusing the bare
  correlation id across several jobs collapses distinct jobs into one consumer
  run; the derivation keeps runs distinct while staying derivable from the
  audit log's correlation id. A depth above zero marks the
  action as nested under an outer operation and adds the `parent` run facet,
  with the parent's id read from the optional `:parent_id_provider` application
  env (a module exporting `parent_id/0`). With no provider configured the parent
  facet is omitted rather than given a fabricated parent id — see
  `AshOpenLineage.CorrelationProvider` for the seam.

  ## Failure posture

  A lineage emitter that can crash a write because a catalogue is down is worse
  than no emitter. Transport rejections are logged as warnings; an unexpected
  exception while building the event is logged with stacktrace and swallowed.
  Both are loud — the logs name the resource, action and reason — but neither
  takes the host's operation down.
  """

  use Ash.Notifier
  require Logger

  @impl true
  def notify(notification) do
    try do
      emit_event(notification)
    rescue
      exception ->
        Logger.error(
          "AshOpenLineage: failed to build lineage event for " <>
            "#{inspect(notification.resource)}.#{notification.action.name}: " <>
            Exception.format(:error, exception, __STACKTRACE__)
        )
    end

    :ok
  end

  defp emit_event(notification) do
    resource = notification.resource
    action = notification.action

    if action.type in AshOpenLineage.Info.lineage_emit_on!(resource) do
      event = AshOpenLineage.Event.run_event(event_opts(notification))

      case send_event(AshOpenLineage.Info.lineage_transport!(resource), event) do
        :ok ->
          :ok

        {:error, error} ->
          Logger.warning(
            "AshOpenLineage: lineage transport rejected the event for " <>
              "#{inspect(resource)}.#{action.name}: #{inspect(error)}"
          )
      end
    end
  end

  # A guard so the checker sees an atom dispatch, not a maybe-tuple module.
  defp send_event(transport, event) when is_atom(transport), do: transport.send(event)

  defp event_opts(notification) do
    resource = notification.resource
    action = notification.action
    namespace = AshOpenLineage.Info.job_namespace(resource)
    job_name = "#{AshOpenLineage.Info.resource_singular(resource)}.#{action.name}"
    {inputs, outputs} = datasets(resource, action.type)
    correlation = AshOpenLineage.correlation_provider()

    [
      event_type: :complete,
      job_namespace: namespace,
      job_name: job_name,
      inputs: inputs,
      outputs: outputs,
      run_id: run_id(correlation.id(), namespace, job_name),
      parent_run_id: parent_run_id(correlation.depth()),
      correlation_id: correlation.id(),
      correlation_depth: correlation.depth(),
      producer: AshOpenLineage.Info.lineage_producer!(resource),
      producer_name: "#{namespace}.#{job_name}"
    ]
  end

  # One OpenLineage run per (correlation, job) pair, NOT per correlation.
  # A correlation id routinely spans several different jobs — one user action
  # writing several tables — and reusing one runId across jobs makes every
  # consumer (Marquez included) collapse them into a single run whose job
  # association flips per event: the runs simply vanish. Deriving a stable,
  # deterministic UUID per (correlation, namespace, job) keeps the audit-log
  # join ("lineage for this audit entry") a bounded lookup — all runs of one
  # correlation share a prefix-derivable id space — while each job keeps its
  # own run. Multiple invocations of the SAME job inside one correlation share
  # that run deliberately: a run is a job execution, and re-emission updates it.
  defp run_id(correlation_id, namespace, job_name) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12), _::binary>> =
      :crypto.hash(:sha256, correlation_id <> "/" <> namespace <> "/" <> job_name)
      |> Base.encode16(case: :lower)

    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp parent_run_id(0), do: nil
  defp parent_run_id(_depth), do: AshOpenLineage.parent_id()

  # create/update write the table (output); destroy removes it (input).
  # A resource with no postgres declaration contributes no dataset at all.
  defp datasets(resource, :destroy),
    do: {wrap(AshOpenLineage.Info.resource_dataset(resource)), []}

  defp datasets(resource, _type),
    do: {[], wrap(AshOpenLineage.Info.resource_dataset(resource))}

  defp wrap(nil), do: []
  defp wrap(dataset), do: [dataset]
end
