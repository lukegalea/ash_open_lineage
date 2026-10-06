# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage do
  @moduledoc """
  The first Elixir OpenLineage emitter: an Ash extension plus a small public
  API, speaking spec **2-0-2** RunEvents.

  Two halves:

    * `AshOpenLineage.Extension` — a Spark `lineage` section for resources.
      It installs `AshOpenLineage.Notifier`, which emits one COMPLETE RunEvent
      per successful create/update/destroy (job name `"{resource}.{action}"`,
      dataset from the `postgres do table end` declaration).
    * `AshOpenLineage.emit/2` / `AshOpenLineage.fail/3` — START / COMPLETE /
      FAIL RunEvents for *non-Ash* jobs: an ingestion wrapper running a Meltano
      tap, a nightly brief, anything that moves data without going through a
      resource action.

  ## The leak rule

  Every facet this library emits carries **structural names only** — job,
  resource, action and table names. Never actor identities, never tenant ids,
  never filter or argument values. Lineage maps the graph of *what moved*;
  who moved it and for whom lives in the host's audit trail. The test suite
  enforces this with injected actor/tenant values, and the rule is binding on
  any facet this library grows.

  ## Configuration

      config :ash_open_lineage,
        # module implementing AshOpenLineage.CorrelationProvider (run ids + depth)
        correlation_provider: AshEnterprise.Platform.Correlation,
        # optional: module exporting parent_id/0 for the parent run facet
        parent_id_provider: MyApp.ParentRunId,
        # transport for AshOpenLineage.emit/2 and AshOpenLineage.fail/3
        # (resources use the per-resource `transport` DSL option instead)
        transport: AshOpenLineage.Transport.Req,
        # base URL for AshOpenLineage.Transport.Req
        http_base_url: "http://localhost:5000"

  See `AshOpenLineage.CorrelationProvider` for the id/depth/parent seam, and
  the README for the two-minute quickstart.
  """

  @producer "https://github.com/lukegalea/ash_open_lineage"

  @type job_descriptor :: %{
          required(:namespace) => String.t(),
          required(:name) => String.t(),
          optional(:inputs) => [AshOpenLineage.Event.dataset_descriptor()],
          optional(:outputs) => [AshOpenLineage.Event.dataset_descriptor()]
        }

  @doc """
  Emits a START or COMPLETE RunEvent for a non-Ash job.

      AshOpenLineage.emit(
        %{
          namespace: "ingestion",
          name: "gmail.sync",
          inputs: ["gmail"],
          outputs: [%{namespace: "warehouse", name: "raw.gmail_messages"}]
        },
        event_type: :start
      )

  The descriptor's `:namespace`/`:name` are required; `:inputs`/`:outputs`
  default to `[]`. Dataset entries may be bare strings (placed in the job's
  namespace), `{namespace, name}` tuples, or maps with `:name`, optional
  `:namespace` and optional `:facets`.

  ## Options

    * `:event_type` — `:start` (default `:complete`).
    * `:run_id` — defaults to the correlation provider's `id/0`; pass one
      explicitly to make START and COMPLETE share a run.
    * `:parent_run_id` — emits the `parent` run facet when present.
    * `:root` — `%{namespace: _, name: _, run_id: _}` for the parent facet's
      v1.52 `root` sub-object.
    * `:producer` — producer URI override.
    * `:event_time` — `%DateTime{}` or ISO8601 binary (tests; defaults to now).

  Returns the transport's result: `:ok` or `{:error, term()}`.
  """
  @spec emit(job_descriptor(), keyword()) :: :ok | {:error, term()}
  def emit(job, opts \\ []) when is_map(job) do
    event_type = Keyword.get(opts, :event_type, :complete)

    unless event_type in [:start, :complete] do
      raise ArgumentError,
            "invalid :event_type #{inspect(event_type)} for emit/2 — use :start or :complete " <>
              "(failures go through fail/3)"
    end

    job
    |> event_opts(opts)
    |> Keyword.put(:event_type, event_type)
    |> AshOpenLineage.Event.run_event()
    |> transport().send()
  end

  @doc """
  Emits a FAIL RunEvent for a non-Ash job — the event that makes a broken tap
  visible instead of silent.

      AshOpenLineage.fail(job, "tap crashed: Google API 410 gone", run_id: run_id)

  `reason` may be a binary, an exception, or any term (inspected). The message
  lands in the `error` run facet's `errorMessage`. Accepts the same `:run_id`,
  `:parent_run_id`, `:root`, `:producer` and `:event_time` options as `emit/2` —
  pass the `run_id` the START used so the failure attaches to the same run.

  Returns the transport's result: `:ok` or `{:error, term()}`.
  """
  @spec fail(job_descriptor(), term(), keyword()) :: :ok | {:error, term()}
  def fail(job, reason, opts \\ []) when is_map(job) do
    job
    |> event_opts(opts)
    |> Keyword.merge(event_type: :fail, error_message: format_reason(reason))
    |> AshOpenLineage.Event.run_event()
    |> transport().send()
  end

  @doc "The producer URI used when no override is configured."
  @spec producer() :: String.t()
  def producer, do: @producer

  @doc """
  The transport for `emit/2`/`fail/3`: the `:transport` application env,
  defaulting to `AshOpenLineage.Transport.Req`. Resources bypass this — their
  transport comes from the `lineage` DSL section.
  """
  @spec transport() :: module()
  def transport do
    Application.get_env(:ash_open_lineage, :transport, AshOpenLineage.Transport.Req)
  end

  @doc """
  The configured `AshOpenLineage.CorrelationProvider`, defaulting to
  `AshOpenLineage.CorrelationProvider.Default` (fresh UUID, depth 0).
  """
  @spec correlation_provider() :: module()
  def correlation_provider do
    Application.get_env(
      :ash_open_lineage,
      :correlation_provider,
      AshOpenLineage.CorrelationProvider.Default
    )
  end

  @doc """
  The enclosing run's id from the optional `:parent_id_provider` env, or `nil`
  when none is configured — the parent facet is then omitted rather than
  fabricated. See `AshOpenLineage.CorrelationProvider`.
  """
  @spec parent_id() :: String.t() | nil
  def parent_id do
    case Application.get_env(:ash_open_lineage, :parent_id_provider) do
      nil -> nil
      provider -> provider.parent_id()
    end
  end

  # --- plumbing ----------------------------------------------------------------

  defp event_opts(job, opts) do
    [
      job_namespace: fetch!(job, :namespace),
      job_name: fetch!(job, :name),
      inputs: Map.get(job, :inputs, []),
      outputs: Map.get(job, :outputs, []),
      producer_name:
        Keyword.get_lazy(opts, :producer_name, fn ->
          "#{Map.fetch!(job, :namespace)}.#{Map.fetch!(job, :name)}"
        end),
      producer: Keyword.get(opts, :producer),
      run_id: Keyword.get(opts, :run_id),
      parent_run_id: Keyword.get(opts, :parent_run_id),
      root: Keyword.get(opts, :root),
      event_time: Keyword.get(opts, :event_time)
    ]
    # An unset option must be *absent*, not present-with-nil: the event builder
    # falls back to configuration for absent keys only.
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fetch!(job, key) do
    case Map.fetch(job, key) do
      {:ok, value} when is_binary(value) ->
        value

      {:ok, other} ->
        raise ArgumentError,
              "job descriptor :#{key} must be a String.t(), got: #{inspect(other)}"

      :error ->
        raise ArgumentError,
              "job descriptor requires :#{key} and :name — got: #{inspect(Map.keys(job))}"
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason

  defp format_reason(%_{} = reason) do
    if is_exception(reason) do
      Exception.message(reason)
    else
      inspect(reason)
    end
  end

  defp format_reason(reason), do: inspect(reason)
end
