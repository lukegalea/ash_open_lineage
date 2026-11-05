defmodule AshOpenLineage.Snapshot.CanonicalJSON do
  @moduledoc """
  RFC 8785 (JSON Canonicalization Scheme) canonical JSON, hand-implemented.

  Produces the byte-exact canonical form used to compute snapshot digests:

    * I-JSON (RFC 7493) values only — anything else is rejected with
      `{:error, {:non_ijson, term}}`.
    * Object property names sorted by UTF-16 code-unit order (§3.2.3).
    * Numbers serialized per ECMAScript `Number::toString` (§3.2.2.3):
      integers plain, no exponent unless required by the ES6 exponent
      bounds (-6 < n <= 21), `-0` becomes `"0"`.
    * Strings escaped exactly as ECMAScript `JSON.stringify` (§3.2.2.2):
      only `"`, `\\` and the C0 controls are escaped, using the short
      forms `\\b \\t \\n \\f \\r` and `\\u00xx` for the rest.
    * Value-type conventions used by the snapshot envelope:
      `%DateTime{}` -> UTC ISO-8601 with exactly six fractional digits + `Z`;
      `%Date{}` -> `YYYY-MM-DD`; module atoms -> dotted alias strings;
      other atoms -> their snake_case name; binaries must be valid UTF-8;
      `nil` -> `null`.

  The module is pure Elixir: no Ash, no external JCS library. Jason is a
  dependency of the package but is *not* JCS-compliant, so it is used only
  for byte-level escaping primitives where safe — the canonical ordering
  and number serialization live here.
  """

  alias AshOpenLineage.Snapshot.{Definition, Input}

  @max_safe_integer 9_007_199_254_740_991

  @type canonical :: binary()

  @doc """
  Encodes a term to canonical JSON.

  Returns `{:ok, iodata}` or `{:error, {:non_ijson, term}}`.
  """
  @spec encode(term()) :: {:ok, canonical()} | {:error, {:non_ijson, term()}}
  def encode(term) do
    case do_encode(prepare(term)) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Like `encode/1` but raises on non-I-JSON input."
  @spec encode!(term()) :: canonical()
  def encode!(term) do
    case encode(term) do
      {:ok, canonical} ->
        canonical

      {:error, {:non_ijson, reason}} ->
        raise ArgumentError, "non-I-JSON value: #{inspect(reason)}"
    end
  end

  @doc """
  SHA-256 hex digest of the canonical encoding of `map` minus the `:digest`
  field. Lowercase hex.
  """
  @spec digest(map()) :: String.t()
  def digest(map) when is_map(map) do
    map
    |> Map.delete(:digest)
    |> encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # -- value preparation (value-type conventions) ---------------------------

  defp prepare(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%6fZ")
  end

  defp prepare(%Date{} = d), do: Date.to_iso8601(d)

  defp prepare(%AshOpenLineage.Snapshot{} = snapshot) do
    %{
      id: snapshot.id,
      purpose: snapshot.purpose,
      effective_at: snapshot.effective_at,
      knowledge_cutoff: snapshot.knowledge_cutoff,
      world: snapshot.world,
      authority: snapshot.authority,
      # §canonical ordering: arrays sorted struct-level before encoding.
      inputs:
        snapshot.inputs
        |> Enum.sort_by(&{&1.key, &1.role})
        |> Enum.map(&input_map/1),
      definitions:
        snapshot.definitions
        |> Enum.sort_by(&{&1.kind, &1.key, &1.version})
        |> Enum.map(&definition_map/1),
      payload_hash: snapshot.payload_hash
    }
  end

  defp prepare(%{__struct__: struct_name} = value) do
    {:error, {:non_ijson, {struct_name, value}}}
  end

  defp prepare(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> rest ->
        rest

      name ->
        if String.valid?(name) and module_like?(name) do
          name
        else
          name
        end
    end
  end

  defp prepare(value), do: value

  defp module_like?(name), do: Regex.match?(~r/^[A-Z]/, name)

  defp input_map(%Input{} = input) do
    %{
      key: input.key,
      role: input.role,
      status: input.status,
      source: input.source,
      content_hash: input.content_hash
    }
  end

  defp definition_map(%Definition{} = defn) do
    %{kind: defn.kind, key: defn.key, version: defn.version, content_hash: defn.content_hash}
  end

  # -- recursive encoding ----------------------------------------------------

  defp do_encode(nil), do: {:ok, "null"}
  defp do_encode(true), do: {:ok, "true"}
  defp do_encode(false), do: {:ok, "false"}

  defp do_encode(value) when is_binary(value) do
    if String.valid?(value) do
      {:ok, [?", escape(value, "", []), ?"]}
    else
      {:error, {:non_ijson, {:invalid_utf8, value}}}
    end
  end

  defp do_encode(value) when is_integer(value) do
    if abs(value) <= @max_safe_integer do
      # Exactly representable as an IEEE 754 double: serialize plainly.
      {:ok, Integer.to_string(value)}
    else
      # RFC 8785 §3.2.2.3 serializes the IEEE 754 double value; integers
      # beyond the double mantissa round-trip through the double.
      value
      |> Kernel.*(1.0)
      |> serialize_double()
    end
  end

  defp do_encode(value) when is_float(value), do: serialize_double(value)

  defp do_encode(value) when is_list(value) do
    case map_ok(value, &do_encode(prepare(&1))) do
      {:ok, encoded} -> {:ok, [?[, Enum.intersperse(encoded, ?,), ?]]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_encode(value) when is_map(value) do
    with {:ok, entries} <- object_entries(value) do
      encoded =
        entries
        |> Enum.sort(&utf16_key_lt?(elem(&1, 0), elem(&2, 0)))
        |> Enum.map(fn {key, encoded_value} ->
          [?", escape(key, "", []), ?", ?:, encoded_value]
        end)
        |> Enum.intersperse(?,)

      {:ok, [?{, encoded, ?}]}
    end
  end

  defp do_encode(other), do: {:error, {:non_ijson, other}}

  # Object entries: keys must be strings, atoms or integers (atom/integer keys
  # are serialized to their string form); duplicates after normalization are
  # non-I-JSON (RFC 7493 §2.3).
  defp object_entries(map) do
    entries =
      Enum.map(map, fn {key, value} ->
        case key_to_string(key) do
          {:ok, key_string} ->
            case do_encode(prepare(value)) do
              {:ok, encoded_value} -> {:ok, {key_string, encoded_value}}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case map_ok(entries, & &1) do
      {:ok, pairs} ->
        keys = Enum.map(pairs, &elem(&1, 0))

        if Enum.uniq(keys) == keys do
          {:ok, pairs}
        else
          {:error, {:non_ijson, {:duplicate_keys, keys}}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp key_to_string(key) when is_binary(key),
    do: (String.valid?(key) && {:ok, key}) || {:error, {:non_ijson, {:invalid_utf8, key}}}

  defp key_to_string(key) when is_atom(key) and not is_boolean(key) and not is_nil(key),
    do: {:ok, prepare(key)}

  defp key_to_string(key) when is_integer(key), do: {:ok, Integer.to_string(key)}
  defp key_to_string(key), do: {:error, {:non_ijson, {:invalid_key, key}}}

  defp map_ok(list, fun) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, :lists.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- §3.2.3: sort by UTF-16 code-unit order --------------------------------

  @doc false
  @spec utf16_key_lt?(String.t(), String.t()) :: boolean()
  def utf16_key_lt?(a, b) do
    utf16_code_units(a) <= utf16_code_units(b)
  end

  defp utf16_code_units(string) do
    Enum.flat_map(String.to_charlist(string), fn
      cp when cp <= 0xFFFF ->
        [cp]

      cp ->
        reduced = cp - 0x10000
        [0xD800 + Bitwise.bsr(reduced, 10), 0xDC00 + Bitwise.band(reduced, 0x3FF)]
    end)
  end

  # -- §3.2.2.2: JSON.stringify string escaping ------------------------------

  defp escape(<<?", rest::binary>>, acc, out), do: escape(rest, <<acc::binary, "\\\"">>, out)
  defp escape(<<?\\, rest::binary>>, acc, out), do: escape(rest, <<acc::binary, "\\\\">>, out)

  defp escape(<<c, rest::binary>>, acc, out) when c in [?\b, ?\f, ?\n, ?\r, ?\t] do
    short = %{?\b => "\\b", ?\f => "\\f", ?\n => "\\n", ?\r => "\\r", ?\t => "\\t"}
    escape(rest, <<acc::binary, short[c]::binary>>, out)
  end

  defp escape(<<c, rest::binary>>, acc, out) when c < 0x20 do
    escape(rest, <<acc::binary, "\\u", hex4(c)::binary>>, out)
  end

  defp escape(<<c::utf8, rest::binary>>, acc, out),
    do: escape(rest, <<acc::binary, c::utf8>>, out)

  defp escape(<<>>, acc, out), do: IO.iodata_to_binary([out, acc])

  defp hex4(c), do: c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")

  # -- §3.2.2.3: ES6 Number::toString for doubles ----------------------------

  defp serialize_double(f) when is_float(f) do
    cond do
      f == 0.0 ->
        {:ok, "0"}

      f != f or abs(f) > 1.7976931348623157e308 ->
        {:error, {:non_ijson, f}}

      true ->
        {:ok, es6_number_to_string(f)}
    end
  end

  defp es6_number_to_string(f) do
    # Erlang's :short gives the shortest round-tripping decimal, either
    # fixed ("0.002") or scientific ("2.0e-3"). Convert to ES6 (s, k, n)
    # terms where value = s * 10^(n - k), s the digit string without
    # leading/trailing zeros, n the decimal exponent of the leading digit.
    {exp_s, int, frac} =
      case String.split(:erlang.float_to_binary(f, [:short]), "e") do
        [mantissa] ->
          parse_mantissa(mantissa)

        [mantissa, exp] ->
          {base, int, frac} = parse_mantissa(mantissa)
          {base + String.to_integer(exp), int, frac}
      end

    fixed_or_exp(int, frac, exp_s)
  end

  defp parse_mantissa(mantissa) do
    case String.split(mantissa, ".", parts: 2) do
      [int] -> {0, int, ""}
      [int, frac] -> {0, int, frac}
    end
  end

  defp fixed_or_exp(int, frac, exp_s) do
    digits = int <> frac
    leading = leading_zero_count(digits, 0)
    s = digits |> String.slice(leading..-1//1) |> String.trim_trailing("0")
    k = String.length(s)
    n = exp_s + String.length(int) - leading

    cond do
      k <= n and n <= 21 ->
        s <> String.duplicate("0", n - k)

      n in 1..21 ->
        [String.slice(s, 0, n), ?., String.slice(s, n..-1//1)]

      n <= 0 and n > -6 ->
        "0." <> String.duplicate("0", -n) <> s

      true ->
        first = String.slice(s, 0, 1)
        rest = String.slice(s, 1..-1//1)
        exponent = n - 1

        if rest == "" do
          "#{first}e#{sign(exponent)}#{abs(exponent)}"
        else
          "#{first}.#{rest}e#{sign(exponent)}#{abs(exponent)}"
        end
    end
  end

  defp leading_zero_count(<<?0, rest::binary>>, acc), do: leading_zero_count(rest, acc + 1)
  defp leading_zero_count(_, acc), do: acc

  defp sign(e) when e >= 0, do: "+"
  defp sign(_e), do: "-"
end
