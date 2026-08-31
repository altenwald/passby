defmodule Passby do
  @moduledoc """
  A 100% Elixir, 0-dependency mock HTTP server for testing HTTP clients.

  `Passby` provides a clean, drop-in replacement for `Bypass` without requiring
  `Plug`, `Cowboy`, or `Ranch`.

  ## Basic Usage

      test "fetches user profile" do
        bypass = Passby.open()

        Passby.expect_once(bypass, "GET", "/api/users/42", fn conn ->
          Passby.Conn.put_resp_header(conn, "content-type", "application/json")
          Passby.Conn.resp(conn, 200, ~s({"id": 42, "name": "Alice"}))
        end)

        assert {:ok, %{"name" => "Alice"}} = MyClient.get_user("\#{bypass.url}/api/users/42")
      end

  ## Plug and Bypass Compatibility

  `Passby.Conn` implements the same attributes and helpers as `Plug.Conn`
  (`get_req_header/2`, `put_resp_header/3`, `resp/3`, `send_resp/1`,
  `fetch_query_params/1`), allowing existing test suites to migrate from
  `Bypass` with zero friction.

  Handlers receive a conn whose `query_params` and `params` are already decoded
  the same way `Bypass`/`Plug.Conn.Query` decode them, including bracket
  notation (`"filter[name]=Manuel"` -> `%{"filter" => %{"name" => "Manuel"}}`)
  and lists (`"tags[]=a&tags[]=b"` -> `%{"tags" => ["a", "b"]}`).
  """

  alias Passby.{Conn, Instance}

  @type t :: %__MODULE__{
          pid: pid(),
          port: :inet.port_number(),
          url: String.t()
        }

  defstruct [:pid, :port, :url]

  @doc """
  Starts a new `Passby` mock HTTP server instance.

  ## Options

    * `:port` - The port number to listen on (default `0` for dynamic ephemeral port).
    * `:bind_address` - The IP address tuple to bind to (default `{127, 0, 0, 1}`).

  ## Examples

      iex> bypass = Passby.open()
      iex> is_integer(bypass.port)
      true
      iex> is_binary(bypass.url)
      true
      iex> bypass.url =~ "http://127.0.0.1:"
      true

  """
  @spec open(keyword()) :: t()
  def open(opts \\ []) do
    {:ok, pid} = Instance.start_link(opts)
    port = Instance.port(pid)
    url = build_url(opts, port)
    %__MODULE__{pid: pid, port: port, url: url}
  end

  @doc """
  Returns the base URL of the `Passby` instance.

  ## Examples

      iex> bypass = Passby.open()
      iex> Passby.url(bypass) == bypass.url
      true

  """
  @spec url(t()) :: String.t()
  def url(%__MODULE__{url: base_url}), do: base_url

  @doc """
  Returns the URL of the `Passby` instance with the given `path` appended.

  ## Examples

      iex> bypass = Passby.open()
      iex> Passby.url(bypass, "/api/users/42") == "\#{bypass.url}/api/users/42"
      true
      iex> Passby.url(bypass, "api/users/42") == "\#{bypass.url}/api/users/42"
      true

  """
  @spec url(t(), String.t()) :: String.t()
  def url(%__MODULE__{url: base_url}, "/" <> _ = path), do: base_url <> path
  def url(%__MODULE__{url: base_url}, path) when is_binary(path), do: "#{base_url}/#{path}"

  @doc """
  Adds an expectation that will be called for any incoming request.

  ## Examples

      Passby.expect(bypass, fn conn ->
        Passby.Conn.resp(conn, 200, "OK")
      end)

  """
  @spec expect(t(), (Conn.t() -> any())) :: :ok
  def expect(%__MODULE__{pid: pid}, fun) when is_function(fun, 1) do
    Instance.expect(pid, nil, nil, fun)
  end

  @doc """
  Adds an expectation for a specific HTTP method and path.

  ## Examples

      Passby.expect(bypass, "POST", "/api/v1/checkout", fn conn ->
        Passby.Conn.resp(conn, 201, "Created")
      end)

  """
  @spec expect(t(), String.t() | atom() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def expect(%__MODULE__{pid: pid}, method, path, fun)
      when (is_binary(method) or is_atom(method) or is_nil(method)) and
             (is_binary(path) or is_nil(path)) and is_function(fun, 1) do
    Instance.expect(pid, method, path, fun)
  end

  @doc """
  Adds an expectation that will be called at most once for any request.
  """
  @spec expect_once(t(), (Conn.t() -> any())) :: :ok
  def expect_once(%__MODULE__{pid: pid}, fun) when is_function(fun, 1) do
    Instance.expect_once(pid, nil, nil, fun)
  end

  @doc """
  Adds an expectation that will be called at most once for a specific method and path.

  ## Examples

      Passby.expect_once(bypass, "DELETE", "/sessions/current", fn conn ->
        Passby.Conn.resp(conn, 204, "")
      end)

  """
  @spec expect_once(t(), String.t() | atom() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def expect_once(%__MODULE__{pid: pid}, method, path, fun)
      when (is_binary(method) or is_atom(method) or is_nil(method)) and
             (is_binary(path) or is_nil(path)) and is_function(fun, 1) do
    Instance.expect_once(pid, method, path, fun)
  end

  @doc """
  Adds a fallback stub handler that matches if no specific expectation matched.
  """
  @spec stub(t(), String.t() | atom() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def stub(%__MODULE__{pid: pid}, method, path, fun)
      when (is_binary(method) or is_atom(method) or is_nil(method)) and
             (is_binary(path) or is_nil(path)) and is_function(fun, 1) do
    Instance.stub(pid, method, path, fun)
  end

  @doc """
  Clears all expectations and stubs configured on the `Passby` instance.
  """
  @spec pass(t()) :: :ok
  def pass(%__MODULE__{pid: pid}) do
    Instance.pass(pid)
  end

  @doc """
  Closes the listening socket to simulate network downtime or connection refused errors.
  """
  @spec down(t()) :: :ok
  def down(%__MODULE__{pid: pid}) do
    Instance.down(pid)
  end

  @doc """
  Reopens the listening socket after being closed with `down/1`.
  """
  @spec up(t()) :: :ok
  def up(%__MODULE__{pid: pid}) do
    Instance.up(pid)
  end

  # Delegates for Conn helpers

  @doc """
  Fetches query params into the connection. Delegate to `Passby.Conn.fetch_query_params/2`.
  """
  defdelegate fetch_query_params(conn), to: Conn
  defdelegate fetch_query_params(conn, opts), to: Conn

  @doc """
  Gets request headers from the connection. Delegate to `Passby.Conn.get_req_header/2`.
  """
  defdelegate get_req_header(conn, header_name), to: Conn

  @doc """
  Sets a response header. Delegate to `Passby.Conn.put_resp_header/3`.
  """
  defdelegate put_resp_header(conn, key, value), to: Conn

  @doc """
  Sets the response status and body. Delegate to `Passby.Conn.resp/3`.
  """
  defdelegate resp(conn, status, body), to: Conn

  @doc """
  Sends the response immediately. Delegate to `Passby.Conn.send_resp/3`.
  """
  defdelegate send_resp(conn, status, body), to: Conn

  @doc """
  Sends the configured response. Delegate to `Passby.Conn.send_resp/1`.
  """
  defdelegate send_resp(conn), to: Conn

  # Private Helpers

  defp build_url(opts, port) do
    host =
      case Keyword.get(opts, :bind_address, {127, 0, 0, 1}) do
        ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
        host when is_binary(host) -> host
      end

    "http://#{host}:#{port}"
  end
end
