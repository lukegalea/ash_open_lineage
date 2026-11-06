defmodule AshOpenLineage.Snapshot.CanonicalJSONTest do
  use ExUnit.Case, async: true

  alias AshOpenLineage.Snapshot
  alias AshOpenLineage.Snapshot.CanonicalJSON

  @fixtures_dir "test/fixtures/jcs"

  # RFC 8785 Appendix B test vectors (vendored from
  # github.com/cyberphone/json-canonicalization, testdata/input + output).
  @jcs_vectors ["arrays", "structures", "values", "weird", "french", "unicode"]

  # Compile-time dependency on every vendored fixture: editing one recompiles
  # this test module (Iron Law #16).
  @external_resource "test/fixtures/jcs/arrays.json"
  @external_resource "test/fixtures/jcs/expected_arrays.json"
  @external_resource "test/fixtures/jcs/structures.json"
  @external_resource "test/fixtures/jcs/expected_structures.json"
  @external_resource "test/fixtures/jcs/values.json"
  @external_resource "test/fixtures/jcs/expected_values.json"
  @external_resource "test/fixtures/jcs/weird.json"
  @external_resource "test/fixtures/jcs/expected_weird.json"
  @external_resource "test/fixtures/jcs/french.json"
  @external_resource "test/fixtures/jcs/expected_french.json"
  @external_resource "test/fixtures/jcs/unicode.json"
  @external_resource "test/fixtures/jcs/expected_unicode.json"

  describe "RFC 8785 Appendix B vectors" do
    for name <- @jcs_vectors do
      test "#{name}.json canonicalizes to expected_#{name}.json" do
        input =
          @fixtures_dir |> Path.join(unquote("#{name}.json")) |> File.read!() |> Jason.decode!()

        expected = @fixtures_dir |> Path.join(unquote("expected_#{name}.json")) |> File.read!()

        assert {:ok, canonical} = CanonicalJSON.encode(input)
        assert canonical == expected
      end
    end
  end

  describe "UTF-16 code-unit key ordering (§3.2.3)" do
    test "orders keys by UTF-16 code units, not code points or locale" do
      # \u2028 (0x2028) < \u00fc? No: 0x00FC < 0x20AC < 0x2028. Assert the
      # classic ordering: Latin-1 < Euro sign < surrogate pair < presentation form.
      input = %{"ü" => 1, "€" => 2, "😀" => 3, "דּ" => 4}

      assert {:ok, canonical} = CanonicalJSON.encode(input)
      assert canonical == ~s({"ü":1,"€":2,"😀":3,"דּ":4})
    end

    test "supplementary-plane characters sort as surrogate pairs" do
      # U+1D400 MATHEMATICAL BOLD CAPITAL A = surrogate pair D835 DC00;
      # its high surrogate D835 sorts BEFORE \uDC00..FFFF code units like U+FB33,
      # but AFTER BMP chars below D800 such as U+20AC.
      input = %{"דּ" => 1, "𝐀" => 2, "€" => 3}

      assert {:ok, canonical} = CanonicalJSON.encode(input)
      assert canonical == ~s({"€":3,"𝐀":2,"דּ":1})
    end
  end

  describe "ES6 Number::toString (§3.2.2.3)" do
    test "integers serialize plain" do
      assert CanonicalJSON.encode!(%{"a" => 1, "b" => -42, "c" => 0}) == ~s({"a":1,"b":-42,"c":0})
    end

    test "negative zero serializes as 0" do
      assert CanonicalJSON.encode!(%{"a" => -0.0}) == ~s({"a":0})
      assert CanonicalJSON.encode!(%{"a" => 0.0}) == ~s({"a":0})
      assert CanonicalJSON.encode!(%{"a" => 0}) == ~s({"a":0})
    end

    test "exponent bounds follow ES6: fixed for 1e-6 <= |x| < 1e21, exponential outside" do
      assert CanonicalJSON.encode!(%{"a" => 1.0e20}) == ~s({"a":100000000000000000000})
      assert CanonicalJSON.encode!(%{"a" => 1.0e21}) == ~s({"a":1e+21})
      assert CanonicalJSON.encode!(%{"a" => 0.000001}) == ~s({"a":0.000001})
      assert CanonicalJSON.encode!(%{"a" => 1.0e-7}) == ~s({"a":1e-7})
      assert CanonicalJSON.encode!(%{"a" => 1.25}) == ~s({"a":1.25})
    end

    test "integers beyond IEEE 754 precision serialize as the double value" do
      assert CanonicalJSON.encode!(%{"a" => 9_007_199_254_740_993}) == ~s({"a":9007199254740992})
    end

    # OTP 28 makes NaN/inf floats unconstructible in the BEAM (arithmetic
    # overflow, bit-syntax matches and external-term decoding all reject
    # them), so there is no non-finite value to feed the encoder; the
    # encoder still guards against them defensively.
  end

  describe "string escaping (§3.2.2.2)" do
    test "escapes only quote, backslash and C0 controls, with short forms" do
      assert CanonicalJSON.encode!(%{"s" => "a\"b\\c\nd\te\x01"}) ==
               ~s({"s":"a\\"b\\\\c\\nd\\te\\u0001"})
    end

    test "DEL (0x7f) is NOT escaped" do
      assert CanonicalJSON.encode!(%{"s" => "\x7f"}) == ~s({"s":"\u{7f}"})
    end

    test "lone-invalid UTF-8 binaries are rejected" do
      assert match?({:error, {:non_ijson, _}}, CanonicalJSON.encode(<<0xFF, 0xFE>>))
    end
  end

  describe "value-type conventions" do
    test "DateTime renders as UTC ISO-8601 with exactly six fractional digits + Z" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-11-05T08:30:00.123456Z")
      assert CanonicalJSON.encode!(%{"t" => dt}) == ~s({"t":"2026-11-05T08:30:00.123456Z"})

      # Non-UTC offsets are converted to UTC.
      {:ok, dt2, _} = DateTime.from_iso8601("2026-11-05T10:30:00.000000+02:00")
      assert CanonicalJSON.encode!(%{"t" => dt2}) == ~s({"t":"2026-11-05T08:30:00.000000Z"})
    end

    test "Date renders as YYYY-MM-DD" do
      assert CanonicalJSON.encode!(%{"d" => ~D[2026-11-05]}) == ~s({"d":"2026-11-05"})
    end

    test "module atoms render as dotted alias strings, enum atoms as snake_case" do
      assert CanonicalJSON.encode!(%{"m" => Some.Module, "e" => :unresolved, "w" => :scenario}) ==
               ~s({"e":"unresolved","m":"Some.Module","w":"scenario"})
    end

    test "nil renders as null" do
      assert CanonicalJSON.encode!(%{"a" => nil}) == ~s({"a":null})
    end
  end

  describe "I-JSON rejection" do
    test "unknown structs are rejected" do
      assert match?(
               {:error, {:non_ijson, _}},
               CanonicalJSON.encode(%{"a" => URI.parse("https://x")})
             )
    end

    test "duplicate keys after normalization are rejected" do
      assert match?({:error, {:non_ijson, _}}, CanonicalJSON.encode(%{"1" => 1, 1 => 2}))
    end

    test "non-string-able map keys are rejected" do
      assert match?({:error, {:non_ijson, _}}, CanonicalJSON.encode(%{{:a, :b} => 1}))
    end
  end

  describe "snapshot envelope" do
    @golden_digest "2be6f74cd9c618c1c0d0513b1acada801eda16113e21e6f33b86d542b73c036d"

    defp golden_snapshot do
      {:ok, eff, _} = DateTime.from_iso8601("2026-11-05T08:30:00.123456Z")
      {:ok, cut, _} = DateTime.from_iso8601("2026-11-04T22:00:00.000000Z")

      %Snapshot{
        id: "019a2c7e-4b1d-7c2e-9f3a-5d6e7f8a9b0c",
        purpose: :"planning.personal_week",
        effective_at: eff,
        knowledge_cutoff: cut,
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
            role: :parameter,
            status: :value,
            source: %{resource: "Policy", id: "pol-9", version_number: 2},
            content_hash: "bb22"
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
          %Snapshot.Definition{
            kind: :mzn,
            key: "personal_week",
            version: "3",
            content_hash: "dd44"
          }
        ],
        payload_hash: "ee55"
      }
    end

    test "cross-host golden digest is stable (re-asserted by a downstream host)" do
      assert Snapshot.put_digest(golden_snapshot()).digest == @golden_digest
    end

    test "digest ignores input list order (struct-level canonical sort)" do
      snap = golden_snapshot()
      reordered = %{snap | inputs: Enum.reverse(snap.inputs)}

      assert Snapshot.put_digest(snap).digest == Snapshot.put_digest(reordered).digest
    end

    test "digest ignores definition list order" do
      snap = golden_snapshot()
      reordered = %{snap | definitions: Enum.reverse(snap.definitions)}

      assert Snapshot.put_digest(snap).digest == Snapshot.put_digest(reordered).digest
    end

    test "digest ignores the pre-existing digest field" do
      snap = Snapshot.put_digest(golden_snapshot())

      assert CanonicalJSON.digest(snap) == snap.digest
    end
  end
end
