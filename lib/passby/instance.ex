defmodule Passby.Instance do
  @moduledoc """
  GenServer that manages an individual `Passby` mock HTTP server instance.
  """

  use GenServer
  require Logger

  alias Passby.{Conn, HttpParser}

  @type t :: %__MODULE__{
          socket: :gen_tcp.socket() | nil,
          port: :inet.port_number() | nil,
          bind_address: :inet.ip4_address() | nil,
          acceptor: pid() | nil,
          expectations: [map()],
          caller: pid() | nil
        }

  defstruct [:socket, :port, :bind_address, :acceptor, :caller, expectations: []]

  @doc """
  Starts a new `Passby.Instance` linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, {self(), opts})
  end

  @doc """
  Returns the port number the instance is listening on.
  """
  @spec port(pid()) :: :inet.port_number()
  def port(server) do
    GenServer.call(server, :port)
  end

  @doc """
  Adds an expectation that will be invoked at most once.
  """
  @spec expect_once(pid(), String.t() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def expect_once(server, method, path, fun) do
    GenServer.call(server, {:add_expectation, :once, method, path, fun})
  end

  @doc """
  Adds an expectation that will be invoked for all matching requests.
  """
  @spec expect(pid(), String.t() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def expect(server, method, path, fun) do
    GenServer.call(server, {:add_expectation, :persistent, method, path, fun})
  end

  @doc """
  Adds a stub handler that matches if no specific expectation matched.
  """
  @spec stub(pid(), String.t() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def stub(server, method, path, fun) do
    GenServer.call(server, {:add_expectation, :stub, method, path, fun})
  end

  @doc """
  Clears all expectations from the instance.
  """
  @spec pass(pid()) :: :ok
  def pass(server) do
    GenServer.call(server, :pass)
  end

  @doc """
  Closes the listening socket to simulate network/server downtime.
  """
  @spec down(pid()) :: :ok
  def down(server) do
    GenServer.call(server, :down)
  end

  @doc """
  Restarts the listening socket after being taken down.
  """
  @spec up(pid()) :: :ok
  def up(server) do
    GenServer.call(server, :up)
  end

  # GenServer Callbacks

  @impl GenServer
  def init({caller, opts}) do
    port = Keyword.get(opts, :port, 0)
    bind_address = Keyword.get(opts, :bind_address, {127, 0, 0, 1})

    case open_listen_socket(port, bind_address) do
      {:ok, socket, actual_port} ->
        state = %__MODULE__{
          socket: socket,
          port: actual_port,
          bind_address: bind_address,
          caller: caller,
          expectations: []
        }

        acceptor = start_acceptor(self(), socket)
        {:ok, %{state | acceptor: acceptor}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, %__MODULE__{port: port} = state) do
    {:reply, port, state}
  end

  def handle_call({:add_expectation, type, method, path, fun}, _from, state) do
    exp = %{
      id: System.unique_integer([:monotonic, :positive]),
      type: type,
      method: normalize_filter(method),
      path: normalize_filter(path),
      fun: fun
    }

    {:reply, :ok, %{state | expectations: upsert_expectation(state.expectations, exp)}}
  end

  def handle_call(:pass, _from, state) do
    {:reply, :ok, %{state | expectations: []}}
  end

  def handle_call(:down, _from, state) do
    if state.socket != nil do
      :gen_tcp.close(state.socket)
    end

    {:reply, :ok, %{state | socket: nil, acceptor: nil}}
  end

  def handle_call(:up, _from, state) do
    if state.socket != nil do
      {:reply, :ok, state}
    else
      case open_listen_socket(state.port, state.bind_address) do
        {:ok, socket, actual_port} ->
          acceptor = start_acceptor(self(), socket)
          {:reply, :ok, %{state | socket: socket, port: actual_port, acceptor: acceptor}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:match_and_consume, method, path}, _from, state) do
    {handler, path_params, new_expectations} = match_and_consume(state.expectations, method, path)
    {:reply, {handler, path_params}, %{state | expectations: new_expectations}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.socket != nil do
      :gen_tcp.close(state.socket)
    end

    :ok
  end

  # Internal Helpers

  defp open_listen_socket(port, bind_address) do
    opts = [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: bind_address,
      backlog: 128
    ]

    case :gen_tcp.listen(port, opts) do
      {:ok, socket} ->
        {:ok, actual_port} = :inet.port(socket)
        {:ok, socket, actual_port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_acceptor(server_pid, socket) do
    spawn_link(fn -> acceptor_loop(server_pid, socket) end)
  end

  defp acceptor_loop(server_pid, socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client_socket} ->
        spawn(fn -> handle_client(server_pid, client_socket) end)
        acceptor_loop(server_pid, socket)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_client(server_pid, client_socket) do
    case HttpParser.parse_request(client_socket) do
      {:ok, conn} ->
        {handler, path_params} =
          GenServer.call(server_pid, {:match_and_consume, conn.method, conn.request_path})

        dispatch_handler(client_socket, put_path_params(conn, path_params), handler)

      {:error, _reason} ->
        :gen_tcp.close(client_socket)
    end
  end

  defp put_path_params(conn, path_params) when map_size(path_params) == 0, do: conn

  defp put_path_params(conn, path_params) do
    %{conn | path_params: path_params, params: Map.merge(conn.params, path_params)}
  end

  defp dispatch_handler(client_socket, conn, nil) do
    resp_body = "No expectation or stub set in Passby for #{conn.method} #{conn.request_path}"

    conn
    |> Conn.resp(500, resp_body)
    |> Conn.send_resp()

    :gen_tcp.close(client_socket)
  end

  defp dispatch_handler(client_socket, conn, fun) when is_function(fun, 1) do
    result = fun.(conn)
    handle_handler_result(client_socket, conn, result)
  rescue
    e ->
      Logger.error("Passby handler raised error: #{Exception.format(:error, e, __STACKTRACE__)}")

      conn
      |> Conn.resp(500, "Internal Server Error in Passby Handler")
      |> Conn.send_resp()
  catch
    :exit, reason ->
      Logger.error("Passby handler caught exit: #{inspect(reason)}")

      conn
      |> Conn.resp(500, "Internal Server Error in Passby Handler")
      |> Conn.send_resp()

    value ->
      Logger.error("Passby handler caught throw: #{inspect(value)}")

      conn
      |> Conn.resp(500, "Internal Server Error in Passby Handler")
      |> Conn.send_resp()
  after
    :gen_tcp.close(client_socket)
  end

  defp handle_handler_result(_socket, _conn, %Conn{state: :sent}) do
    :ok
  end

  defp handle_handler_result(_socket, _conn, %Conn{} = updated_conn) do
    _ = Conn.send_resp(updated_conn)
    :ok
  end

  defp handle_handler_result(_socket, conn, %{
         status: status,
         resp_body: body,
         resp_headers: headers
       }) do
    updated_conn = %{conn | status: status, resp_body: body, resp_headers: headers}
    _ = Conn.send_resp(updated_conn)
    :ok
  end

  defp handle_handler_result(_socket, conn, _other) do
    _ = Conn.send_resp(conn, 200, "OK")
    :ok
  end

  # Priority matching:
  # 1. :once expectations (in FIFO order) - consumed on match
  # 2. :persistent expectations (in FIFO order) - kept on match
  # 3. :stub expectations (in FIFO order) - kept on match
  defp match_and_consume(expectations, method, path) do
    case find_and_consume_once(expectations, method, path, []) do
      {:matched, fun, params, new_exps} ->
        {fun, params, new_exps}

      :not_found ->
        find_persistent_or_stub(expectations, method, path)
    end
  end

  defp find_persistent_or_stub(expectations, method, path) do
    case find_matching(expectations, :persistent, method, path) do
      {:matched, fun, params} ->
        {fun, params, expectations}

      :not_found ->
        case find_matching(expectations, :stub, method, path) do
          {:matched, fun, params} -> {fun, params, expectations}
          :not_found -> {nil, %{}, expectations}
        end
    end
  end

  defp find_matching(expectations, type, method, path) do
    Enum.reduce_while(expectations, :not_found, fn
      %{type: ^type} = exp, acc ->
        case match_expectation(exp, method, path) do
          {:ok, params} -> {:halt, {:matched, exp.fun, params}}
          :error -> {:cont, acc}
        end

      _exp, acc ->
        {:cont, acc}
    end)
  end

  defp find_and_consume_once([], _method, _path, _acc), do: :not_found

  defp find_and_consume_once([%{type: :once} = exp | rest], method, path, acc) do
    case match_expectation(exp, method, path) do
      {:ok, params} -> {:matched, exp.fun, params, Enum.reverse(acc) ++ rest}
      :error -> find_and_consume_once(rest, method, path, [exp | acc])
    end
  end

  defp find_and_consume_once([exp | rest], method, path, acc) do
    find_and_consume_once(rest, method, path, [exp | acc])
  end

  defp match_expectation(%{method: exp_method, path: exp_path}, req_method, req_path) do
    if is_nil(exp_method) or exp_method == req_method do
      match_path(exp_path, req_path)
    else
      :error
    end
  end

  defp match_path(nil, _req_path), do: {:ok, %{}}

  defp match_path(exp_path, req_path) do
    exp_segments = String.split(exp_path, "/", trim: true)
    req_segments = String.split(req_path, "/", trim: true)

    if length(exp_segments) == length(req_segments) do
      match_segments(exp_segments, req_segments, %{})
    else
      :error
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | exp_rest], [value | req_rest], params) do
    match_segments(exp_rest, req_rest, Map.put(params, name, value))
  end

  defp match_segments([same | exp_rest], [same | req_rest], params) do
    match_segments(exp_rest, req_rest, params)
  end

  defp match_segments(_exp_segments, _req_segments, _params), do: :error

  # Redefining an expectation for the same {type, method, path} replaces the
  # previous one in place (last definition wins), matching Bypass, which keys
  # routes by {method, path}. Distinct routes keep their registration order.
  defp upsert_expectation(expectations, exp) do
    case Enum.find_index(expectations, fn e ->
           e.type == exp.type and e.method == exp.method and e.path == exp.path
         end) do
      nil -> expectations ++ [exp]
      index -> List.replace_at(expectations, index, exp)
    end
  end

  defp normalize_filter(nil), do: nil
  defp normalize_filter(atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.upcase()
  defp normalize_filter(binary) when is_binary(binary), do: binary
end
