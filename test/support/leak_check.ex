# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshOpenLineage.TestSupport.LeakCheck do
  @moduledoc """
  The leak rule, executable: raises unless the built event is clean.

  A lineage event must carry structural names only — job, resource, action,
  table. This walks the whole term (map keys included, any depth) and raises
  `ExUnit.AssertionError` listing every place a forbidden string appears.

  Deliberately sharp-edged, and the suite first proves the blade cuts: the leak
  test runs it against a deliberately-leaking map and asserts the raise before
  trusting it with real events.
  """

  alias ExUnit.AssertionError

  @spec assert_clean!(term(), [String.t()]) :: :ok
  def assert_clean!(term, forbidden) when is_list(forbidden) do
    case leaks(term, forbidden, []) do
      [] ->
        :ok

      leaks ->
        raise AssertionError,
          message:
            "lineage event leaks forbidden values:\n" <>
              Enum.map_join(leaks, "\n", fn {path, value} ->
                "  #{path}: #{inspect(value)}"
              end) <>
              "\nforbidden: #{inspect(forbidden)}"
    end
  end

  defp leaks(binary, forbidden, path) when is_binary(binary) do
    if Enum.any?(forbidden, &String.contains?(binary, &1)) do
      [{path(binary, path), binary}]
    else
      []
    end
  end

  defp leaks(atom, forbidden, path) when is_atom(atom) and not is_boolean(atom) do
    leaks(Atom.to_string(atom), forbidden, path)
  end

  defp leaks(map, forbidden, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      leaks(key, forbidden, path ++ ["<key>"]) ++ leaks(value, forbidden, path)
    end)
  end

  defp leaks(list, forbidden, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> leaks(item, forbidden, path ++ ["[#{index}]"]) end)
  end

  defp leaks(_other, _forbidden, _path), do: []

  defp path(nil, []), do: "<root>"
  defp path(_value, []), do: "<root>"
  defp path(value, path), do: "#{Enum.join(path, ".")} = #{inspect(value)}"
end
