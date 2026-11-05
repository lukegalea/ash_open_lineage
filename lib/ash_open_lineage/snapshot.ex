defmodule AshOpenLineage.Snapshot do
  @moduledoc """
  Snapshot value contract for planning proposals (PLN-3).

  A snapshot is the immutable, digest-carrying envelope a planning kernel
  proposes against: who is asking, as of when, over which knowledge horizon,
  with which resolved inputs and which pinned model definitions. It carries
  references and hashes only — never resource payloads.

  Shared vocabulary (owner decision 2026-11-05, reconciliation round 0.2.1):
  `purpose` is a dotted atom (e.g. `:"extraction.quote_v1"`,
  `:"planning.personal_week"`, extensible by deliberate first-party edit);
  `world` is `:operational | :scenario`; input `status` is
  `:value | :unresolved | :invalid | :missing_citation`.

  Pure data: no Ash dependency. Digest computation lives in
  `AshOpenLineage.Snapshot.CanonicalJSON` (RFC 8785 canonical JSON).
  """

  defmodule Input do
    @moduledoc "One snapshot input: a reference to a read resource row and its content hash."

    @enforce_keys [:key, :role, :status]
    defstruct [:key, :role, :status, :source, :content_hash]

    @type source :: %{
            required(:resource) => module() | String.t(),
            required(:id) => String.t(),
            required(:version_number) => integer()
          }

    @type status :: :value | :unresolved | :invalid | :missing_citation | atom()

    @type t :: %__MODULE__{
            key: String.t(),
            role: atom(),
            status: status(),
            source: source() | nil,
            content_hash: String.t() | nil
          }
  end

  defmodule Definition do
    @moduledoc "One pinned definition (model, checker, validator) in the snapshot."

    @enforce_keys [:kind, :key, :version, :content_hash]
    defstruct [:kind, :key, :version, :content_hash]

    @type kind :: :dmn | :bpmn | :mzn | :validator | atom()

    @type t :: %__MODULE__{
            kind: kind(),
            key: String.t(),
            version: String.t(),
            content_hash: String.t()
          }
  end

  @enforce_keys [:id, :purpose, :effective_at, :knowledge_cutoff, :world, :authority]
  defstruct [
    :id,
    :purpose,
    :effective_at,
    :knowledge_cutoff,
    :world,
    :authority,
    :inputs,
    :definitions,
    :payload_hash,
    :digest
  ]

  @type authority :: %{
          required(:tenant) => String.t() | nil,
          required(:actor_id) => String.t() | nil,
          required(:completeness) => atom()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          purpose: atom(),
          effective_at: DateTime.t(),
          knowledge_cutoff: DateTime.t(),
          world: :operational | :scenario | atom(),
          authority: authority(),
          inputs: [Input.t()],
          definitions: [Definition.t()],
          payload_hash: String.t() | nil,
          digest: String.t() | nil
        }

  @doc """
  Returns the snapshot with `digest` computed over the canonical encoding of
  every other field (RFC 8785, SHA-256 hex, lowercase).
  """
  @spec put_digest(t()) :: t()
  def put_digest(%__MODULE__{} = snapshot) do
    %{snapshot | digest: AshOpenLineage.Snapshot.CanonicalJSON.digest(snapshot)}
  end
end
