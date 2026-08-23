defmodule Passby.HttpParser do
  @moduledoc """
  Parses raw HTTP/1.0 and HTTP/1.1 requests from a `:gen_tcp` socket
  using Erlang's built-in `:erlang.decode_packet/3`.
  """

  alias Passby.Conn

  @recv_timeout 5_000

  @doc """
  Reads and parses an HTTP request from the given `:gen_tcp` socket.

  Returns `{:ok, %Passby.Conn{}}` or `{:error, reason}`.
  """
  @spec parse_request(port(), binary(), timeout()) ::
          {:ok, Conn.t()} | {:error, :closed | :timeout | atom()}
  def parse_request(socket, buffer \\ <<>>, timeout \\ @recv_timeout) do
    with {:ok, initial_data} <- ensure_data(socket, buffer, timeout),
         {:ok, request_line, rest} <- decode_request_line(socket, initial_data, timeout),
         {:ok, headers, body_buffer} <- decode_headers(socket, rest, [], timeout),
         {:ok, body} <- read_body(socket, headers, body_buffer, timeout) do
      {method, path, query_string, path_info} = parse_request_line(request_line)

      conn = %Conn{
        adapter: {Passby, socket},
        method: method,
        request_path: path,
        path_info: path_info,
        query_string: query_string,
        req_headers: headers,
        req_body: body,
        state: :unset
      }

      {:ok, conn}
    end
  end

  defp ensure_data(_socket, buffer, _timeout) when byte_size(buffer) > 0, do: {:ok, buffer}

  defp ensure_data(socket, _buffer, timeout) do
    :gen_tcp.recv(socket, 0, timeout)
  end

  defp decode_request_line(socket, buffer, timeout) do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      {:ok, {:http_request, method, uri, version}, rest} ->
        {:ok, {method, uri, version}, rest}

      {:ok, {:http_error, _}, _rest} ->
        {:error, :bad_request}

      {:more, _} ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, more_data} -> decode_request_line(socket, buffer <> more_data, timeout)
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_headers(socket, buffer, headers, timeout) do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:ok, {:http_header, _, field, _, value}, rest} ->
        header_name = normalize_header_name(field)
        decode_headers(socket, rest, headers ++ [{header_name, to_string(value)}], timeout)

      {:ok, :http_eoh, rest} ->
        {:ok, headers, rest}

      {:ok, {:http_error, _}, _rest} ->
        {:error, :bad_header}

      {:more, _} ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, more_data} -> decode_headers(socket, buffer <> more_data, headers, timeout)
          error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_body(socket, headers, initial_buffer, timeout) do
    content_length = get_content_length(headers)

    cond do
      content_length == 0 ->
        {:ok, ""}

      byte_size(initial_buffer) >= content_length ->
        <<body::binary-size(content_length), _rest::binary>> = initial_buffer
        {:ok, body}

      true ->
        needed = content_length - byte_size(initial_buffer)
        read_remaining_body(socket, initial_buffer, needed, timeout)
    end
  end

  defp read_remaining_body(_socket, buffer, 0, _timeout), do: {:ok, buffer}

  defp read_remaining_body(socket, buffer, needed, timeout) do
    case :gen_tcp.recv(socket, min(needed, 65_536), timeout) do
      {:ok, chunk} ->
        new_buffer = buffer <> chunk
        remaining = needed - byte_size(chunk)
        read_remaining_body(socket, new_buffer, remaining, timeout)

      error ->
        error
    end
  end

  defp get_content_length(headers) do
    case Enum.find(headers, fn {k, _v} -> String.downcase(k) == "content-length" end) do
      {_, value} ->
        case Integer.parse(String.trim(value)) do
          {len, _} when len >= 0 -> len
          _ -> 0
        end

      nil ->
        0
    end
  end

  defp parse_request_line({method, uri, _version}) do
    method_str = normalize_method(method)
    raw_path = extract_raw_path(uri)

    uri_struct = URI.parse(raw_path)
    path = uri_struct.path || "/"
    query = uri_struct.query || ""

    path_info =
      path
      |> String.split("/", trim: true)

    {method_str, path, query, path_info}
  end

  defp normalize_method(atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.upcase()
  defp normalize_method(binary) when is_binary(binary), do: String.upcase(binary)

  defp extract_raw_path({:abs_path, path}), do: to_string(path)
  defp extract_raw_path({:absoluteURI, _scheme, _host, _port, path}), do: to_string(path)
  defp extract_raw_path(other), do: to_string(other)

  defp normalize_header_name(atom) when is_atom(atom),
    do: atom |> Atom.to_string() |> String.downcase()

  defp normalize_header_name(binary) when is_binary(binary), do: String.downcase(binary)
end
