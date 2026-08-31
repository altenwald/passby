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

  Expectation paths may use `:param` segments (`"/users/:id"`); captured values
  land in `conn.path_params` and are merged into `conn.params`.

  ## Verification

  Expectations are verified when the test that opened the instance finishes.
  `expect/2,4` must receive at least one request, `expect_once/2,4` exactly one,
  `expect/3,5` exactly the number given, and a request matching no expectation
  fails the test. `stub/4` is never verified. An error raised inside a handler
  (a failed `assert`, for instance) is re-raised at verification instead of
  being swallowed by the `500` the client receives.

  Verification is automatic under ExUnit. Outside of it, call
  `verify_expectations!/1` yourself, or pass `verify: false` to `open/1` when
  using `Passby` as a plain fake server rather than as a test double.
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
    * `:verify` - Whether to verify expectations automatically when the test
      exits (default `true`). Has no effect outside a test process.

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
    case start_instance(opts) do
      {:ok, pid} ->
        port = Instance.port(pid)
        url = build_url(opts, port)
        bypass = %__MODULE__{pid: pid, port: port, url: url}
        setup_verification(bypass, opts)
        bypass

      {:error, reason} ->
        raise "Failed to start Passby instance: #{inspect(reason)}"
    end
  end

  @doc """
  Verifies the expectations declared on the instance, raising on failure.

  Under ExUnit this runs automatically when the test exits, so calling it is
  only needed to assert mid-test, or when driving `Passby` from another test
  framework.

  ## Examples

      bypass = Passby.open()
      Passby.expect_once(bypass, "GET", "/health", &Passby.Conn.resp(&1, 200, "ok"))
      _ = :httpc.request(~c"\#{bypass.url}/health")

      Passby.verify_expectations!(bypass)
      #=> :ok

  """
  @spec verify_expectations!(t()) :: :ok | no_return()
  def verify_expectations!(%__MODULE__{pid: pid}) do
    pid
    |> Instance.verify()
    |> raise_verification_error()
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

  The `path` may contain `:param` segments; the captured values are placed in
  `conn.path_params` and merged into `conn.params` (path params win over query
  params on key conflicts), matching `Bypass`.

  ## Examples

      Passby.expect(bypass, "POST", "/api/v1/checkout", fn conn ->
        Passby.Conn.resp(conn, 201, "Created")
      end)

      Passby.expect(bypass, "GET", "/users/:id", fn conn ->
        Passby.Conn.resp(conn, 200, ~s({"id": \#{conn.params["id"]}}))
      end)

  """
  @spec expect(t(), String.t() | atom() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def expect(%__MODULE__{pid: pid}, method, path, fun)
      when (is_binary(method) or is_atom(method) or is_nil(method)) and
             (is_binary(path) or is_nil(path)) and is_function(fun, 1) do
    Instance.expect(pid, method, path, fun)
  end

  @doc """
  Expects the passed function to be called exactly `count` times, regardless of
  the route.

  ## Examples

      Passby.expect(bypass, 3, fn conn ->
        Passby.Conn.resp(conn, 200, "OK")
      end)

  """
  @spec expect(t(), pos_integer(), (Conn.t() -> any())) :: :ok
  def expect(%__MODULE__{pid: pid}, count, fun)
      when is_integer(count) and count > 0 and is_function(fun, 1) do
    Instance.expect(pid, count, nil, nil, fun)
  end

  @doc """
  Expects the passed function to be called exactly `count` times for a specific
  method and path.

  ## Examples

      Passby.expect(bypass, "POST", "/events", 2, fn conn ->
        Passby.Conn.resp(conn, 202, "")
      end)

  """
  @spec expect(
          t(),
          String.t() | atom() | nil,
          String.t() | nil,
          pos_integer(),
          (Conn.t() -> any())
        ) :: :ok
  def expect(%__MODULE__{pid: pid}, method, path, count, fun)
      when (is_binary(method) or is_atom(method) or is_nil(method)) and
             (is_binary(path) or is_nil(path)) and is_integer(count) and count > 0 and
             is_function(fun, 1) do
    Instance.expect(pid, count, method, path, fun)
  end

  @doc """
  Adds an expectation that must be called exactly once, regardless of the route.
  """
  @spec expect_once(t(), (Conn.t() -> any())) :: :ok
  def expect_once(%__MODULE__{pid: pid}, fun) when is_function(fun, 1) do
    Instance.expect_once(pid, nil, nil, fun)
  end

  @doc """
  Adds an expectation that must be called exactly once for a specific method and path.

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
  Makes the instance pass verification, whatever its expectations recorded.

  Useful when the request is issued from a process the test cannot await, or
  when a handler is expected to fail on purpose.

  ## Examples

      Passby.expect(bypass, fn conn ->
        Passby.pass(bypass)
        Passby.Conn.resp(conn, 200, "")
      end)

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

  defp start_instance(opts) do
    opts = Keyword.put(opts, :caller, self())

    case DynamicSupervisor.start_child(Passby.InstanceSupervisor, {Instance, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp setup_verification(%__MODULE__{pid: pid}, opts) do
    if Keyword.get(opts, :verify, true) and register_on_exit(pid) do
      Instance.arm_verification(pid)
    end

    :ok
  end

  # Verification hooks into ExUnit through `on_exit/2`, which ships with Elixir
  # and so costs no dependency. Outside a test process there is nothing to hook
  # into: the instance keeps its "dies with its caller" lifecycle, and
  # verification is left to `verify_expectations!/1`.
  defp register_on_exit(pid) do
    if Code.ensure_loaded?(ExUnit.Callbacks) do
      ExUnit.Callbacks.on_exit({__MODULE__, pid}, fn ->
        pid
        |> Instance.on_exit()
        |> raise_verification_error()
      end)

      true
    else
      false
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  defp raise_verification_error(:ok), do: :ok

  defp raise_verification_error({:exit, {kind, reason, stacktrace}}) do
    :erlang.raise(kind, reason, stacktrace)
  end

  defp raise_verification_error(error) do
    message = verification_message(error)

    if Code.ensure_loaded?(ExUnit.AssertionError) do
      raise ExUnit.AssertionError, message
    else
      raise message
    end
  end

  defp verification_message({:error, :too_many_requests, route}) do
    "Expected only one HTTP request for Passby#{at(route)}"
  end

  defp verification_message({:error, {:unexpected_request_number, expected, actual}, route}) do
    "Expected #{expected} HTTP requests for Passby#{at(route)}, got #{actual}"
  end

  defp verification_message({:error, :unexpected_request, route}) do
    "Passby got an HTTP request but wasn't expecting one#{at(route)}"
  end

  defp verification_message({:error, :not_called, route}) do
    "No HTTP request arrived at Passby#{at(route)}"
  end

  defp verification_message({:error, :instance_not_running}) do
    "The Passby instance is no longer running, so its expectations could not be verified"
  end

  defp at({:any, :any}), do: ""
  defp at({method, path}), do: " at #{method} #{path}"

  defp build_url(opts, port) do
    host =
      case Keyword.get(opts, :bind_address, {127, 0, 0, 1}) do
        ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
        host when is_binary(host) -> host
      end

    "http://#{host}:#{port}"
  end
end
