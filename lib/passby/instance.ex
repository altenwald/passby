defmodule Passby.Instance do
  @moduledoc """
  GenServer that manages an individual `Passby` mock HTTP server instance.

  Besides serving requests, the instance records everything needed to verify
  expectations when the test that opened it finishes: how many requests each
  expectation received, requests that matched no expectation, and errors raised
  inside handlers. See `Passby.verify_expectations!/1`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Passby.{Conn, HttpParser}

  @typedoc """
  The `{method, path}` an expectation was registered for. `:any` is used for the
  method and the path of expectations registered without a route.
  """
  @type route :: {String.t() | :any, String.t() | :any}

  @typedoc """
  How many requests an expectation must receive to be considered met.
  """
  @type expected :: :once | :once_or_more | :none_or_more | {:exactly, pos_integer()}

  @typedoc """
  A verification failure. `Passby` turns these into assertion errors.
  """
  @type error ::
          {:error, :unexpected_request | :too_many_requests | :not_called, route()}
          | {:error, {:unexpected_request_number, pos_integer(), non_neg_integer()}, route()}
          | {:error, :instance_not_running}
          | {:exit, {Exception.kind(), term(), Exception.stacktrace()}}

  @typedoc """
  A request waiting for the handlers still in flight to finish.
  """
  @type awaiting :: {:verify | :on_exit | :down, GenServer.from(), pid()}

  @type t :: %__MODULE__{
          socket: :gen_tcp.socket() | nil,
          port: :inet.port_number() | nil,
          bind_address: :inet.ip4_address() | nil,
          acceptor: pid() | nil,
          caller: pid() | nil,
          caller_monitor: reference() | nil,
          expectations: [map()],
          handlers: %{reference() => pid()},
          awaiting: [awaiting()],
          unknown_route_errors: [error()],
          over_limit_errors: [error()],
          handler_errors: [error()],
          pass: boolean(),
          verify_armed: boolean()
        }

  defstruct [
    :socket,
    :port,
    :bind_address,
    :acceptor,
    :caller,
    :caller_monitor,
    expectations: [],
    handlers: %{},
    awaiting: [],
    unknown_route_errors: [],
    over_limit_errors: [],
    handler_errors: [],
    pass: false,
    verify_armed: false
  ]

  # Expectations are matched in this order. Within a priority, registration
  # order wins.
  @priorities [:once, :persistent, :stub]

  @doc """
  Starts a new `Passby.Instance`.

  The process that will be verified when the instance exits is taken from the
  `:caller` option, defaulting to the calling process. Instances are normally
  started under `Passby.InstanceSupervisor` by `Passby.open/1`, which passes the
  test process as `:caller`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {caller, opts} = Keyword.pop(opts, :caller, self())
    GenServer.start_link(__MODULE__, {caller, opts})
  end

  @doc """
  Returns the port number the instance is listening on.
  """
  @spec port(pid()) :: :inet.port_number()
  def port(server) do
    GenServer.call(server, :port)
  end

  @doc """
  Adds an expectation that must be invoked exactly once.
  """
  @spec expect_once(pid(), String.t() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def expect_once(server, method, path, fun) do
    add_expectation(server, :once, :once, method, path, fun)
  end

  @doc """
  Adds an expectation that must be invoked at least once.
  """
  @spec expect(pid(), String.t() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def expect(server, method, path, fun) do
    add_expectation(server, :persistent, :once_or_more, method, path, fun)
  end

  @doc """
  Adds an expectation that must be invoked exactly `count` times.
  """
  @spec expect(pid(), pos_integer(), String.t() | nil, String.t() | nil, (Conn.t() -> any())) ::
          :ok
  def expect(server, count, method, path, fun) when is_integer(count) and count > 0 do
    add_expectation(server, :persistent, {:exactly, count}, method, path, fun)
  end

  @doc """
  Adds a stub handler that matches if no specific expectation matched.

  Stubs are never verified: they may be called any number of times, including
  none.
  """
  @spec stub(pid(), String.t() | nil, String.t() | nil, (Conn.t() -> any())) :: :ok
  def stub(server, method, path, fun) do
    add_expectation(server, :stub, :none_or_more, method, path, fun)
  end

  @doc """
  Marks the instance as passing, so verification always succeeds.

  Also releases the handlers still in flight, so a handler that calls this and
  then `down/1` is not waiting on itself. This is what Bypass does.
  """
  @spec pass(pid()) :: :ok
  def pass(server) do
    GenServer.call(server, :pass)
  end

  @doc """
  Closes the listening socket to simulate network/server downtime.

  Blocks until the handlers still in flight have finished, so that closing the
  socket cannot cut off a response that is still being written. A handler
  calling this for its own instance does not wait for itself.
  """
  @spec down(pid()) :: :ok
  def down(server) do
    GenServer.call(server, :down, :infinity)
  end

  @doc """
  Restarts the listening socket after being taken down.
  """
  @spec up(pid()) :: :ok
  def up(server) do
    GenServer.call(server, :up)
  end

  @doc """
  Marks the instance as verified automatically when the caller exits.

  Once armed, the instance outlives its caller so that the test framework
  callback registered by `Passby.open/1` can still verify and stop it.
  """
  @spec arm_verification(pid()) :: :ok
  def arm_verification(server) do
    GenServer.call(server, :arm_verification)
  end

  @doc """
  Returns the verification result without stopping the instance.

  Blocks until the handlers still in flight have finished, so that a handler
  about to fail cannot be missed. Returns `:ok` or the first `t:error/0` found.
  """
  @spec verify(pid()) :: :ok | error()
  def verify(server) do
    GenServer.call(server, :verify, :infinity)
  catch
    # An instance that is gone cannot be verified. Reporting that beats
    # reporting success: instances are supervised with `restart: :temporary`,
    # so a crashed one would otherwise leave the test green.
    :exit, _reason -> {:error, :instance_not_running}
  end

  @doc """
  Returns the verification result and stops the instance.

  Like `verify/1`, but the instance is stopped once it has been verified.
  """
  @spec on_exit(pid()) :: :ok | error()
  def on_exit(server) do
    GenServer.call(server, :on_exit, :infinity)
  catch
    :exit, _reason -> {:error, :instance_not_running}
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
          caller_monitor: Process.monitor(caller),
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

  def handle_call({:add_expectation, type, expected, method, path, fun}, _from, state) do
    exp = %{
      id: System.unique_integer([:monotonic, :positive]),
      type: type,
      expected: expected,
      method: normalize_filter(method),
      path: normalize_filter(path),
      fun: fun,
      request_count: 0
    }

    {:reply, :ok, %{state | expectations: upsert_expectation(state.expectations, exp)}}
  end

  def handle_call(:pass, _from, state) do
    {:reply, :ok, %{release_handlers(state) | pass: true}, {:continue, :dispatch_awaiting}}
  end

  def handle_call(:arm_verification, _from, state) do
    {:reply, :ok, %{state | verify_armed: true}}
  end

  def handle_call(:verify, from, state) do
    await_handlers(:verify, from, state)
  end

  def handle_call(:on_exit, from, state) do
    await_handlers(:on_exit, from, state)
  end

  def handle_call({:handler_error, error}, _from, state) do
    {:reply, :ok, %{state | handler_errors: state.handler_errors ++ [error]}}
  end

  def handle_call(:down, from, state) do
    await_handlers(:down, from, state)
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

  def handle_call({:match_and_consume, method, path}, {handler, _tag}, state) do
    state = track_handler(state, handler)

    case match_expectations(state.expectations, method, path) do
      {:matched, exp, path_params} ->
        {:reply, {exp.fun, path_params}, count_request(state, exp.id)}

      :no_match ->
        {:reply, {nil, %{}}, record_unmatched(state, method, path)}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{caller_monitor: ref} = state) do
    # An armed instance outlives its caller: the test framework callback still
    # has to verify it. Otherwise there is nobody left to report to.
    if state.verify_armed do
      {:noreply, %{state | caller_monitor: nil}}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.handlers, ref) do
    state
    |> forget_handler(ref)
    |> record_handler_exit(reason)
    |> dispatch_awaiting()
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_continue(:dispatch_awaiting, state), do: dispatch_awaiting(state)

  @impl GenServer
  def terminate(_reason, state) do
    if state.socket != nil do
      :gen_tcp.close(state.socket)
    end

    :ok
  end

  # In-flight handlers
  #
  # Every request is served by its own process, so verification, and closing
  # the socket, have to wait for the ones still running: a handler that has not
  # finished may still fail, and a socket closed underneath it truncates a
  # response the client is reading. A handler asking for its own instance never
  # waits for itself, which is what lets a handler call `down/1` or `verify/1`.

  defp await_handlers(action, {caller, _tag} = from, state) do
    if handlers_pending?(state, caller) do
      {:noreply, %{state | awaiting: state.awaiting ++ [{action, from, caller}]}}
    else
      run_action(action, state)
    end
  end

  defp run_action(:verify, state), do: {:reply, verification_result(state), state}
  defp run_action(:on_exit, state), do: {:stop, :normal, verification_result(state), state}
  defp run_action(:down, state), do: {:reply, :ok, close_socket(state)}

  defp dispatch_awaiting(state) do
    {ready, waiting} =
      Enum.split_with(state.awaiting, fn {_action, _from, caller} ->
        not handlers_pending?(state, caller)
      end)

    state = %{state | awaiting: waiting}
    {exiting, replying} = Enum.split_with(ready, &match?({:on_exit, _from, _caller}, &1))

    state = Enum.reduce(replying, state, &reply_awaiting/2)

    case exiting do
      [] ->
        {:noreply, state}

      awaiting ->
        Enum.each(awaiting, fn {_action, from, _caller} ->
          GenServer.reply(from, verification_result(state))
        end)

        {:stop, :normal, state}
    end
  end

  defp reply_awaiting({:verify, from, _caller}, state) do
    GenServer.reply(from, verification_result(state))
    state
  end

  defp reply_awaiting({:down, from, _caller}, state) do
    state = close_socket(state)
    GenServer.reply(from, :ok)
    state
  end

  defp handlers_pending?(state, except) do
    Enum.any?(state.handlers, fn {_ref, pid} -> pid != except end)
  end

  defp track_handler(state, handler) do
    if Enum.any?(state.handlers, fn {_ref, pid} -> pid == handler end) do
      state
    else
      put_in(state.handlers[Process.monitor(handler)], handler)
    end
  end

  defp forget_handler(state, ref) do
    {_pid, state} = pop_in(state.handlers[ref])
    state
  end

  # `pass/1` releases the handlers still in flight, matching Bypass: the test
  # has said it is done, so nothing is waited for or reported any more.
  defp release_handlers(state) do
    Enum.each(state.handlers, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)
    %{state | handlers: %{}}
  end

  # A handler killed from the outside never reports, so its expectation would
  # otherwise look satisfied by a request nothing answered.
  defp record_handler_exit(state, :normal), do: state

  defp record_handler_exit(state, reason) do
    %{state | handler_errors: state.handler_errors ++ [{:exit, {:exit, reason, []}}]}
  end

  defp close_socket(%__MODULE__{socket: nil} = state), do: state

  defp close_socket(state) do
    :gen_tcp.close(state.socket)
    %{state | socket: nil, acceptor: nil}
  end

  # Verification
  #
  # Precedence follows Bypass: a request for a route nothing declared is
  # reported first, then a declared route that did not get the requests it was
  # promised, then a route that got too many, then an error raised by a handler.

  defp verification_result(%__MODULE__{pass: true}), do: :ok

  defp verification_result(state) do
    List.first(state.unknown_route_errors) ||
      unmet_expectation_error(state.expectations) ||
      List.first(state.over_limit_errors) ||
      List.first(state.handler_errors) ||
      :ok
  end

  defp unmet_expectation_error(expectations) do
    expectations
    |> Enum.reject(&(&1.expected == :none_or_more))
    |> Enum.find_value(&unmet_error/1)
  end

  defp unmet_error(%{expected: {:exactly, count}, request_count: count}), do: nil

  defp unmet_error(%{expected: {:exactly, expected}, request_count: actual} = exp) do
    {:error, {:unexpected_request_number, expected, actual}, route(exp)}
  end

  defp unmet_error(%{request_count: 0} = exp), do: {:error, :not_called, route(exp)}

  defp unmet_error(_exp), do: nil

  defp record_unmatched(state, method, path) do
    case find_exhausted(state.expectations, method, path) do
      %{expected: :once} = exp ->
        over_limit(state, exp, {:error, :too_many_requests, route(exp)})

      %{expected: {:exactly, expected}} = exp ->
        # Counting the excess too, so that the report says how many requests
        # actually arrived rather than always one more than expected.
        error =
          {:error, {:unexpected_request_number, expected, exp.request_count + 1}, route(exp)}

        over_limit(state, exp, error)

      nil ->
        error = {:error, :unexpected_request, {method, path}}
        %{state | unknown_route_errors: state.unknown_route_errors ++ [error]}
    end
  end

  # The stored error replaces the route's previous one rather than piling up:
  # only the final count of a route that was called too often is worth
  # reporting.
  defp over_limit(state, exp, error) do
    route = route(exp)
    errors = Enum.reject(state.over_limit_errors, fn {:error, _reason, r} -> r == route end)

    %{count_request(state, exp.id) | over_limit_errors: errors ++ [error]}
  end

  defp count_request(state, id) do
    expectations =
      Enum.map(state.expectations, fn
        %{id: ^id} = exp -> %{exp | request_count: exp.request_count + 1}
        exp -> exp
      end)

    %{state | expectations: expectations}
  end

  defp route(%{method: method, path: path}), do: {method || :any, path || :any}

  # Internal Helpers

  defp add_expectation(server, type, expected, method, path, fun) do
    GenServer.call(server, {:add_expectation, type, expected, method, path, fun})
  end

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

        dispatch_handler(server_pid, client_socket, put_path_params(conn, path_params), handler)

      {:error, _reason} ->
        :gen_tcp.close(client_socket)
    end
  end

  defp put_path_params(conn, path_params) when map_size(path_params) == 0, do: conn

  defp put_path_params(conn, path_params) do
    %{conn | path_params: path_params, params: Map.merge(conn.params, path_params)}
  end

  defp dispatch_handler(_server_pid, client_socket, conn, nil) do
    resp_body = "No expectation or stub set in Passby for #{conn.method} #{conn.request_path}"

    conn
    |> Conn.resp(500, resp_body)
    |> Conn.send_resp()

    :gen_tcp.close(client_socket)
  end

  defp dispatch_handler(server_pid, client_socket, conn, fun) when is_function(fun, 1) do
    result = fun.(conn)
    handle_handler_result(client_socket, conn, result)
  rescue
    exception ->
      handler_failed(server_pid, conn, :error, exception, __STACKTRACE__)
  catch
    :exit, reason ->
      handler_failed(server_pid, conn, :exit, reason, __STACKTRACE__)

    value ->
      handler_failed(server_pid, conn, :throw, value, __STACKTRACE__)
  after
    :gen_tcp.close(client_socket)
  end

  # The handler crashed. Report the failure before answering, so that the
  # verification that follows the response cannot race it, then answer 500 so
  # the client under test sees a server error instead of a dropped connection.
  defp handler_failed(server_pid, conn, kind, reason, stacktrace) do
    Logger.error("Passby handler #{kind}: #{Exception.format(kind, reason, stacktrace)}")

    GenServer.call(server_pid, {:handler_error, {:exit, {kind, reason, stacktrace}}})

    conn
    |> Conn.resp(500, "Internal Server Error in Passby Handler")
    |> Conn.send_resp()

    :ok
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
  # 1. :once expectations that have not been called yet (FIFO)
  # 2. :persistent expectations that still accept requests (FIFO)
  # 3. :stub expectations (FIFO), which always accept requests
  defp match_expectations(expectations, method, path) do
    Enum.find_value(@priorities, :no_match, fn type ->
      find_matching(expectations, type, method, path)
    end)
  end

  defp find_matching(expectations, type, method, path) do
    Enum.find_value(expectations, fn exp ->
      with %{type: ^type} <- exp,
           true <- available?(exp),
           {:ok, params} <- match_expectation(exp, method, path) do
        {:matched, exp, params}
      else
        _other -> nil
      end
    end)
  end

  # Called after matching failed, to tell "this route was already satisfied"
  # apart from "no such route".
  defp find_exhausted(expectations, method, path) do
    Enum.find(expectations, fn exp ->
      not available?(exp) and match_expectation(exp, method, path) != :error
    end)
  end

  defp available?(%{expected: :once, request_count: count}), do: count == 0
  defp available?(%{expected: {:exactly, n}, request_count: count}), do: count < n
  defp available?(_exp), do: true

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
  # The replacement starts over: its request count is the new one.
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
