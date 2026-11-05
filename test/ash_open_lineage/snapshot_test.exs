defmodule AshOpenLineage.SnapshotTest do
  use ExUnit.Case, async: true

  alias AshOpenLineage.Snapshot

  @eff "2026-11-05T08:30:00.123456Z"
  @cut "2026-11-04T22:00:00.000000Z"

  defp effective_at do
    {:ok, dt, _} = DateTime.from_iso8601(@eff)
    dt
  end

  defp knowledge_cutoff do
    {:ok, dt, _} = DateTime.from_iso8601(@cut)
    dt
  end

  def build_snapshot do
    %Snapshot{
      id: "019a2c7e-4b1d-7c2e-9f3a-5d6e7f8a9b0c",
      purpose: :"planning.personal_week",
      effective_at: effective_at(),
      knowledge_cutoff: knowledge_cutoff(),
      world: :operational,
      authority: %{tenant: "t-demo-01", actor_id: "usr-042", completeness: :full},
      inputs: [
        %Snapshot.Input{
          key: "task.alpha",
          role: :demand,
          status: :value,
          source: %{resource: "Task", id: "task-1", version_number: 7},
          content_hash: "aa11"
        },
        %Snapshot.Input{
          key: "policy.hours",
          role: :constraint,
          status: :unresolved,
          source: nil,
          content_hash: nil
        }
      ],
      definitions: [
        %Snapshot.Definition{
          kind: :dmn,
          key: "canonical.planning_requirements",
          version: "1.0.0",
          content_hash: "cc33"
        },
        %Snapshot.Definition{kind: :mzn, key: "personal_week", version: "3", content_hash: "dd44"}
      ],
      payload_hash: "ee55"
    }
  end

  describe "struct" do
    test "constructs with all contract fields" do
      snap = build_snapshot()

      assert %Snapshot{} = snap
      assert is_binary(snap.id)
      assert snap.purpose == :"planning.personal_week"
      assert %DateTime{} = snap.effective_at
      assert %DateTime{} = snap.knowledge_cutoff
      assert snap.world == :operational
      assert %{tenant: _, actor_id: _, completeness: _} = snap.authority
      assert length(snap.inputs) == 2
      assert length(snap.definitions) == 2
      assert snap.payload_hash == "ee55"
    end

    test "put_digest/1 sets a lowercase hex sha256 digest" do
      snap = Snapshot.put_digest(build_snapshot())

      assert Regex.match?(~r/^[0-9a-f]{64}$/, snap.digest)
    end

    test "put_digest/1 is deterministic" do
      d1 = Snapshot.put_digest(build_snapshot()).digest
      d2 = Snapshot.put_digest(build_snapshot()).digest

      assert d1 == d2
    end

    test "digest excludes the digest field itself" do
      snap = Snapshot.put_digest(build_snapshot())
      rehashed = Snapshot.CanonicalJSON.digest(snap)

      assert rehashed == snap.digest
    end
  end

  describe "digest mutation sensitivity" do
    defp digest_of(snap), do: Snapshot.put_digest(snap).digest

    test "any top-level field change flips the digest" do
      base = Snapshot.put_digest(build_snapshot()).digest

      mutations = [
        {"id", &%{&1 | id: "other-id"}},
        {"purpose", &%{&1 | purpose: :"extraction.quote_v1"}},
        {"effective_at", &%{&1 | effective_at: DateTime.add(&1.effective_at, 1, :second)}},
        {"knowledge_cutoff",
         &%{&1 | knowledge_cutoff: DateTime.add(&1.knowledge_cutoff, 1, :second)}},
        {"world", &%{&1 | world: :scenario}},
        {"authority.tenant", &%{&1 | authority: %{&1.authority | tenant: "t-other"}}},
        {"authority.actor_id", &%{&1 | authority: %{&1.authority | actor_id: "usr-999"}}},
        {"authority.completeness", &%{&1 | authority: %{&1.authority | completeness: :partial}}},
        {"payload_hash", &%{&1 | payload_hash: "ff66"}}
      ]

      for {name, mutate} <- mutations do
        assert digest_of(mutate.(build_snapshot())) != base,
               "digest did not flip on #{name}"
      end
    end

    test "nested input changes flip the digest" do
      base = digest_of(build_snapshot())
      snap = build_snapshot()
      [first, second] = snap.inputs

      mutations = [
        {"input key", &List.replace_at(&1.inputs, 0, %{first | key: "task.beta"})},
        {"input role", &List.replace_at(&1.inputs, 0, %{first | role: :constraint})},
        {"input status", &List.replace_at(&1.inputs, 0, %{first | status: :invalid})},
        {"input source id",
         &List.replace_at(&1.inputs, 0, %{first | source: %{first.source | id: "task-2"}})},
        {"input source version_number",
         &List.replace_at(&1.inputs, 0, %{first | source: %{first.source | version_number: 8}})},
        {"input content_hash", &List.replace_at(&1.inputs, 0, %{first | content_hash: "zz99"})},
        {"second input content_hash",
         &List.replace_at(&1.inputs, 1, %{second | content_hash: "yy88"})}
      ]

      for {name, mutate} <- mutations do
        assert digest_of(%{snap | inputs: mutate.(snap)}) != base,
               "digest did not flip on #{name}"
      end
    end

    test "input LIST ORDER does not flip the digest (canonical (key, role) sort)" do
      base = digest_of(build_snapshot())
      reordered = %{build_snapshot() | inputs: Enum.reverse(build_snapshot().inputs)}

      assert digest_of(reordered) == base
    end

    test "definition content changes flip the digest, list order does not" do
      base = digest_of(build_snapshot())
      snap = build_snapshot()
      [dmn, mzn] = snap.definitions

      assert digest_of(%{snap | definitions: Enum.reverse(snap.definitions)}) == base

      assert digest_of(%{snap | definitions: [%{dmn | kind: :bpmn}, mzn]}) != base
      assert digest_of(%{snap | definitions: [dmn, %{mzn | version: "4"}]}) != base
      assert digest_of(%{snap | definitions: [dmn, %{mzn | content_hash: "zz77"}]}) != base
    end
  end
end
