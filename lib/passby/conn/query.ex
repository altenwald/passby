defmodule Passby.Conn.Query do
  @moduledoc """
  Decodes `x-www-form-urlencoded` query strings into Elixir maps.

  This mirrors the semantics of `Plug.Conn.Query.decode/1` so that `Passby`
  handlers receive the exact same `conn.query_params`/`conn.params` shape they
  would get from `Bypass`, without depending on `Plug`.

      iex> Passby.Conn.Query.decode("filter[name]=Manuel")
      %{"filter" => %{"name" => "Manuel"}}

      iex> Passby.Conn.Query.decode("tags[]=a&tags[]=b")
      %{"tags" => ["a", "b"]}

  Rules:

    * `foo=bar` becomes `%{"foo" => "bar"}`.
    * A repeated scalar key keeps the last value: `foo=1&foo=2` -> `%{"foo" => "2"}`.
    * A key without a value is treated as an empty string: `foo` -> `%{"foo" => ""}`.
    * `foo[bar]=baz` builds nested maps: `%{"foo" => %{"bar" => "baz"}}`.
    * `foo[]=a&foo[]=b` builds a list, preserving order: `%{"foo" => ["a", "b"]}`.
    * Keys and values are URL-decoded (`+` becomes a space, `%XX` octets are decoded).

  Nesting inside lists (for example `foo[][bar]=1`) is ambiguous and its exact
  output should not be relied upon, matching `Plug`.
  """

  @doc """
  Decodes the given `query` string into a map.
  """
  @spec decode(binary()) :: %{optional(String.t()) => term()}
  def decode(query) when is_binary(query) do
    query
    |> String.split("&")
    |> Enum.reduce(%{}, &decode_pair/2)
  end

  defp decode_pair("", acc), do: acc

  defp decode_pair(pair, acc) do
    {key, value} =
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {URI.decode_www_form(key), URI.decode_www_form(value)}
        [key] -> {URI.decode_www_form(key), ""}
      end

    put_path(acc, key_segments(key), value)
  end

  # Splits a key such as `foo[bar][]` into `["foo", "bar", :list]`.
  defp key_segments(key) do
    if key != "" and String.ends_with?(key, "]") and String.contains?(key, "[") do
      without_trailing = binary_part(key, 0, byte_size(key) - 1)
      [head, rest] = :binary.split(without_trailing, "[")
      normalize_segments([head | :binary.split(rest, "][", [:global])])
    else
      [key]
    end
  end

  # A trailing empty segment means "append to a list"; any other empty segment
  # is dropped (nesting inside lists is unspecified in Plug).
  defp normalize_segments(segments) do
    {leading, [last]} = Enum.split(segments, length(segments) - 1)

    leading = Enum.reject(leading, &(&1 == ""))
    last = if last == "", do: :list, else: last

    leading ++ [last]
  end

  defp put_path(acc, [key], value) when is_binary(key) do
    Map.put(acc, key, value)
  end

  defp put_path(acc, [key, :list], value) when is_binary(key) do
    Map.update(acc, key, [value], fn
      existing when is_list(existing) -> existing ++ [value]
      _ -> [value]
    end)
  end

  defp put_path(acc, [key | rest], value) when is_binary(key) do
    child =
      case Map.get(acc, key) do
        %{} = map -> map
        _ -> %{}
      end

    Map.put(acc, key, put_path(child, rest, value))
  end

  # A bare `[]=value` (key resolves to just a list marker) has nowhere to go.
  defp put_path(acc, [:list], _value), do: acc
end
