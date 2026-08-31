defmodule Passby.Conn do
  @moduledoc """
  Represents an HTTP connection in `Passby`.

  This struct and its helper functions provide a familiar, lightweight API
  compatible with `Plug.Conn` and `Bypass` handler functions without requiring
  `Plug` as a dependency.
  """

  alias Passby.Conn.Query

  @type params :: %{optional(String.t()) => term()}

  @type t :: %__MODULE__{
          adapter: {module(), any()},
          host: String.t(),
          port: :inet.port_number() | nil,
          method: String.t(),
          request_path: String.t(),
          path_info: [String.t()],
          query_string: String.t(),
          params: params(),
          query_params: params(),
          path_params: params(),
          req_headers: [{String.t(), String.t()}],
          req_body: binary(),
          status: integer() | nil,
          resp_headers: [{String.t(), String.t()}],
          resp_body: binary() | nil,
          state: :unset | :set | :sent
        }

  defstruct adapter: {Passby, nil},
            host: "127.0.0.1",
            port: nil,
            method: "GET",
            request_path: "/",
            path_info: [],
            query_string: "",
            params: %{},
            query_params: %{},
            path_params: %{},
            req_headers: [],
            req_body: "",
            status: nil,
            resp_headers: [{"content-type", "text/plain; charset=utf-8"}],
            resp_body: nil,
            state: :unset

  @doc """
  Gets the values of the specified request header.

  Header names are case-insensitive. Returns a list of string values matching
  the header name (or an empty list if not present).

  ## Examples

      iex> conn = %Passby.Conn{req_headers: [{"soapaction", "sessionOpen"}]}
      iex> Passby.Conn.get_req_header(conn, "SoapAction")
      ["sessionOpen"]

  """
  @spec get_req_header(t(), String.t()) :: [String.t()]
  def get_req_header(%__MODULE__{req_headers: headers}, header_name)
      when is_binary(header_name) do
    target = String.downcase(header_name)

    headers
    |> Enum.filter(fn {k, _v} -> String.downcase(k) == target end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  @doc """
  Fetches query parameters from the query string and stores them on the conn.

  Populates `conn.query_params` with the decoded query string and merges the
  result into `conn.params`. Any params already present on the conn (for
  example path params) take precedence over query params on key conflicts.

  Bracket notation is decoded the same way `Plug.Conn.Query` decodes it, so
  `"filter[name]=Manuel"` becomes `%{"filter" => %{"name" => "Manuel"}}`.

  The optional second argument is accepted for `Plug.Conn.fetch_query_params/2`
  compatibility and is currently ignored.

  ## Examples

      iex> conn = %Passby.Conn{query_string: "filter[name]=Manuel"}
      iex> conn = Passby.Conn.fetch_query_params(conn)
      iex> conn.query_params
      %{"filter" => %{"name" => "Manuel"}}
      iex> conn.params
      %{"filter" => %{"name" => "Manuel"}}

  """
  @spec fetch_query_params(t(), keyword()) :: t()
  def fetch_query_params(%__MODULE__{} = conn, _opts \\ []) do
    query_params = Query.decode(conn.query_string)
    %{conn | query_params: query_params, params: Map.merge(query_params, conn.params)}
  end

  @doc """
  Sets or adds a response header.

  ## Examples

      iex> conn = %Passby.Conn{}
      iex> conn = Passby.Conn.put_resp_header(conn, "content-type", "application/json")
      iex> conn.resp_headers
      [{"content-type", "application/json"}]

  """
  @spec put_resp_header(t(), String.t(), String.t()) :: t()
  def put_resp_header(%__MODULE__{resp_headers: headers} = conn, key, value)
      when is_binary(key) and is_binary(value) do
    target = String.downcase(key)
    filtered = Enum.reject(headers, fn {k, _v} -> String.downcase(k) == target end)
    %{conn | resp_headers: filtered ++ [{key, value}]}
  end

  @doc """
  Sets the response status and body without immediately transmitting it.

  ## Examples

      iex> conn = %Passby.Conn{}
      iex> conn = Passby.Conn.resp(conn, 200, "Hello World")
      iex> conn.status
      200
      iex> conn.resp_body
      "Hello World"

  """
  @spec resp(t(), integer(), binary()) :: t()
  def resp(%__MODULE__{} = conn, status, body) when is_integer(status) and is_binary(body) do
    %{conn | status: status, resp_body: body, state: :set}
  end

  @doc """
  Sends the response with the given status and body over the underlying socket.

  If no status and body are passed, it sends the response configured in the struct.
  """
  @spec send_resp(t(), integer(), binary()) :: t()
  def send_resp(%__MODULE__{} = conn, status, body) when is_integer(status) and is_binary(body) do
    conn
    |> resp(status, body)
    |> send_resp()
  end

  @doc """
  Sends the response configured in the connection struct over the socket.
  """
  @spec send_resp(t()) :: t()
  def send_resp(%__MODULE__{state: :sent} = conn), do: conn

  def send_resp(%__MODULE__{adapter: {_, socket}, status: status, resp_body: body} = conn) do
    status = status || 200
    body = body || ""

    content_length = byte_size(body)

    headers =
      conn.resp_headers
      |> put_header_if_missing("content-length", Integer.to_string(content_length))
      |> put_header_if_missing("connection", "close")

    raw_response = format_http_response(status, headers, body)

    if socket != nil and is_port(socket) do
      _ = :gen_tcp.send(socket, raw_response)
    end

    %{conn | status: status, resp_body: body, state: :sent}
  end

  defp put_header_if_missing(headers, key, value) do
    target = String.downcase(key)

    if Enum.any?(headers, fn {k, _} -> String.downcase(k) == target end) do
      headers
    else
      headers ++ [{key, value}]
    end
  end

  defp format_http_response(status, headers, body) do
    reason = reason_phrase(status)
    header_lines = Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end)
    ["HTTP/1.1 #{status} #{reason}\r\n", header_lines, "\r\n", body]
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(201), do: "Created"
  defp reason_phrase(202), do: "Accepted"
  defp reason_phrase(204), do: "No Content"
  defp reason_phrase(301), do: "Moved Permanently"
  defp reason_phrase(302), do: "Found"
  defp reason_phrase(304), do: "Not Modified"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(405), do: "Method Not Allowed"
  defp reason_phrase(422), do: "Unprocessable Entity"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(502), do: "Bad Gateway"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(504), do: "Gateway Timeout"
  defp reason_phrase(_), do: "Custom"
end
