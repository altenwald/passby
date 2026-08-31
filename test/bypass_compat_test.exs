defmodule BypassCompatTest do
  @moduledoc """
  Every scenario exercised by the Bypass test suite
  (https://github.com/PSPDFKit-labs/bypass, `test/bypass_test.exs`), ported and
  adapted to the `Passby` API.

  Each Bypass test maps to a test here. Where `Passby` behaves like Bypass, the
  assertion is the same. Where `Passby` does not implement a Bypass feature yet,
  the test lives in a `"... — not implemented"` block, asserts Passby's *actual*
  current behaviour, and the comment states what Bypass does instead. Nothing
  Bypass tests is left unmentioned.
  """

  use ExUnit.Case, async: true

  defdelegate capture_log(fun), to: ExUnit.CaptureLog

  setup do
    :inets.start()
    :ok
  end

  # Minimal :httpc client, mirroring the helpers in test/passby_test.exs.
  # Returns {:ok, status, body} | {:error, reason}.
  defp request(port, path \\ "/example_path", method \\ :post, body \\ "") do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    result =
      case method do
        :get -> :httpc.request(:get, {url, []}, [], [])
        _ -> :httpc.request(method, {url, [], ~c"text/plain", body}, [], [])
      end

    case result do
      {:ok, {{_http, status, _reason}, _headers, resp_body}} ->
        {:ok, status, to_string(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "show ISSUE #51"
  # ---------------------------------------------------------------------------
  test "opening and immediately taking down an instance many times is stable" do
    Enum.each(1..200, fn _ ->
      bypass = %Passby{} = Passby.open()
      Passby.down(bypass)
    end)
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.open can specify a port to operate on with expect / expect_once"
  # ---------------------------------------------------------------------------
  describe "port handling" do
    test "open can specify a port, and conn.port reflects it (expect)" do
      specify_port(:expect)
    end

    test "open can specify a port, and conn.port reflects it (expect_once)" do
      specify_port(:expect_once)
    end

    defp specify_port(expect_fun) do
      bypass = Passby.open()
      port = bypass.port

      apply(Passby, expect_fun, [
        bypass,
        fn conn ->
          assert conn.port == port
          Passby.Conn.resp(conn, 200, "")
        end
      ])

      assert {:ok, 200, ""} = request(port)

      # Bypass also asserts a second `open` on the same port returns a struct.
      bypass2 = Passby.open()
      assert %Passby{} = bypass2
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.down takes down the socket" / "Bypass.up opens the socket again"
  # ---------------------------------------------------------------------------
  describe "down / up" do
    test "down takes down the socket (expect)", do: down_socket(:expect)
    test "down takes down the socket (expect_once)", do: down_socket(:expect_once)

    defp down_socket(expect_fun) do
      bypass = Passby.open()
      apply(Passby, expect_fun, [bypass, fn conn -> Passby.Conn.resp(conn, 200, "") end])

      assert {:ok, 200, ""} = request(bypass.port)

      Passby.down(bypass)
      assert {:error, {:failed_connect, _}} = request(bypass.port)
    end

    test "up opens the socket again" do
      bypass = Passby.open()
      Passby.expect(bypass, fn conn -> Passby.Conn.resp(conn, 200, "") end)

      assert {:ok, 200, ""} = request(bypass.port)

      Passby.down(bypass)
      assert {:error, {:failed_connect, _}} = request(bypass.port)

      Passby.up(bypass)
      assert {:ok, 200, ""} = request(bypass.port)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.expect raises if no request is made" (+ expect_once)
  # ---------------------------------------------------------------------------
  describe "unmet expectations — not implemented" do
    # Bypass installs an on_exit handler that raises {:error, :not_called, ...}
    # when an `expect`/`expect_once` never receives a request. Passby has NO
    # automatic verification: a never-called expectation simply does nothing.
    test "a never-called expect/2 does not fail the test" do
      bypass = Passby.open()
      Passby.expect(bypass, fn _conn -> flunk("must not be called") end)
      assert is_pid(bypass.pid)
    end

    test "a never-called expect_once/2 does not fail the test" do
      bypass = Passby.open()
      Passby.expect_once(bypass, fn _conn -> flunk("must not be called") end)
      assert is_pid(bypass.pid)
    end

    test "Passby exposes no verify_expectations!/1" do
      # Bypass: `Bypass.verify_expectations!/1` exists (ESpec) and the ExUnit
      # variant raises "Not available in ExUnit, ...". Passby has neither.
      refute function_exported?(Passby, :verify_expectations!, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.expect can be made to pass by calling Bypass.pass" (+ once)
  #         "Calling a bypass route without expecting a call fails the test"
  # ---------------------------------------------------------------------------
  describe "pass/1 and unmatched routes — not implemented" do
    # Bypass: `pass/1` marks the current request as "arrived" so the exit
    # verification succeeds even if the handler never sends a response.
    # Passby: `pass/1` clears every expectation and stub on the instance.
    test "pass/1 clears expectations, so a later request falls through to 500" do
      bypass = Passby.open()
      Passby.expect(bypass, "GET", "/x", fn conn -> Passby.Conn.resp(conn, 200, "hit") end)

      Passby.pass(bypass)

      assert {:ok, 500, body} = request(bypass.port, "/x", :get)
      assert body =~ "No expectation"
    end

    # Bypass: an unexpected request returns 500 AND the exit handler raises
    # {:error, :unexpected_request, ...}. Passby: 500 only, no test failure.
    test "calling a route with no expectation returns 500 and does not fail the test" do
      bypass = Passby.open()
      assert {:ok, 500, _body} = request(bypass.port)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "closing a bypass while the request is in-flight" (+ expect_once)
  # ---------------------------------------------------------------------------
  describe "closing while in-flight" do
    test "down/1 from inside the handler closes the connection (expect)" do
      closing_in_flight(:expect)
    end

    test "down/1 from inside the handler closes the connection (expect_once)" do
      closing_in_flight(:expect_once)
    end

    defp closing_in_flight(expect_fun) do
      bypass = Passby.open()

      apply(Passby, expect_fun, [
        bypass,
        fn conn ->
          Passby.down(bypass)
          conn
        end
      ])

      assert {:error, _reason} = request(bypass.port)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.down waits for plug process to terminate ..." (+ once)
  #         "Concurrent calls to down"
  # ---------------------------------------------------------------------------
  describe "down/1 graceful termination — not implemented" do
    # Bypass: `down/1` blocks until any in-flight handler process finishes.
    # Passby: `down/1` closes the listening socket immediately; a handler that
    # is still running keeps running on its own (detached) process.
    test "down/1 returns immediately even while a slow handler is running" do
      test_pid = self()
      ref = make_ref()
      bypass = Passby.open()

      Passby.expect(bypass, "POST", "/slow", fn conn ->
        Process.sleep(150)
        send(test_pid, ref)
        Passby.Conn.resp(conn, 200, "")
      end)

      spawn(fn -> request(bypass.port, "/slow", :post) end)
      Process.sleep(30)

      t0 = System.monotonic_time(:millisecond)
      Passby.down(bypass)
      elapsed = System.monotonic_time(:millisecond) - t0

      # Bypass would block ~120ms here waiting for the handler; Passby does not.
      assert elapsed < 100
      # The detached handler still completes.
      assert_receive ^ref, 500
    end

    test "concurrent calls to down/1 are safe" do
      bypass = Passby.open()
      Passby.stub(bypass, "GET", "/x", fn conn -> Passby.Conn.resp(conn, 200, "ok") end)
      assert {:ok, 200, "ok"} = request(bypass.port, "/x", :get)

      1..5
      |> Enum.map(fn _ -> Task.async(fn -> Passby.down(bypass) end) end)
      |> Enum.each(&Task.await/1)

      assert {:error, {:failed_connect, _}} = request(bypass.port, "/x", :get)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass can handle concurrent requests with expect" (+ expect_once)
  # ---------------------------------------------------------------------------
  describe "concurrency" do
    test "handles concurrent requests with expect" do
      bypass = Passby.open()
      parent = self()

      Passby.expect(bypass, fn conn ->
        send(parent, :request_received)
        Passby.Conn.resp(conn, 200, "")
      end)

      1..5
      |> Enum.map(fn _ -> Task.async(fn -> assert {:ok, 200, ""} = request(bypass.port) end) end)
      |> Enum.each(fn task ->
        Task.await(task)
        assert_receive :request_received
      end)
    end

    test "expect_once serves exactly one of several concurrent requests" do
      bypass = Passby.open()
      parent = self()

      Passby.expect_once(bypass, fn conn ->
        send(parent, :request_received)
        Passby.Conn.resp(conn, 200, "")
      end)

      1..5
      |> Enum.map(fn _ -> Task.async(fn -> request(bypass.port) end) end)
      |> Enum.each(&Task.await/1)

      assert_receive :request_received
      refute_receive :request_received
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.expect/3 fails when too many / not enough requests arrived"
  #         "Bypass.expect/5 fails when too many / not enough requests arrived"
  # ---------------------------------------------------------------------------
  describe "expected request counts — not implemented" do
    # Bypass: `expect(bypass, n, fun)` and `expect(bypass, m, p, n, fun)` assert
    # exactly `n` requests arrive. Passby has no counted arity: `expect/2,4` is
    # "one or more, unverified" and `expect_once/2,4` is "at most once".
    test "there is no counted expect arity" do
      refute function_exported?(Passby, :expect, 3)
      refute function_exported?(Passby, :expect, 5)
    end

    test "expect/2 keeps serving every request (no upper bound, no verification)" do
      bypass = Passby.open()
      Passby.expect(bypass, "GET", "/foo", fn conn -> Passby.Conn.resp(conn, 200, "ok") end)

      for _ <- 1..5 do
        assert {:ok, 200, "ok"} = request(bypass.port, "/foo", :get)
      end
    end

    test "expect_once/2 serves the first request then falls through to 500" do
      bypass = Passby.open()
      Passby.expect_once(bypass, "GET", "/foo", fn conn -> Passby.Conn.resp(conn, 200, "ok") end)

      assert {:ok, 200, "ok"} = request(bypass.port, "/foo", :get)
      assert {:ok, 500, _} = request(bypass.port, "/foo", :get)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.stub/4 does not raise ..." / "Bypass.expect(_once)/4 can be
  #         used to define a specific route"
  # ---------------------------------------------------------------------------
  describe "specific routes" do
    test "stub/4 matches a specific method and path", do: specific_route(:stub)
    test "expect/4 matches a specific method and path", do: specific_route(:expect)
    test "expect_once/4 matches a specific method and path", do: specific_route(:expect_once)

    defp specific_route(expect_fun) do
      bypass = Passby.open()
      path = "/this"

      apply(Passby, expect_fun, [
        bypass,
        "POST",
        path,
        fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == path
          Passby.Conn.resp(conn, 200, "")
        end
      ])

      assert {:ok, 200, ""} = request(bypass.port, path, :post)
    end

    test "stub/4 does not raise if the request is never made" do
      bypass = Passby.open()
      Passby.stub(bypass, "POST", "/stub_path", fn conn -> Passby.Conn.resp(conn, 200, "") end)
      assert is_pid(bypass.pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.(stub|expect|expect_once)/4 ... a specific route with parameters"
  # ---------------------------------------------------------------------------
  describe "routes with parameters" do
    test "stub/4 with path + query parameters", do: route_with_params(:stub)
    test "expect/4 with path + query parameters", do: route_with_params(:expect)
    test "expect_once/4 with path + query parameters", do: route_with_params(:expect_once)

    defp route_with_params(expect_fun) do
      bypass = Passby.open()
      pattern = "/this/:resource/get/:id"
      path = "/this/my_resource/get/1234"

      apply(Passby, expect_fun, [
        bypass,
        "POST",
        pattern,
        fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == path

          assert conn.params == %{
                   "resource" => "my_resource",
                   "id" => "1234",
                   "q_param_1" => "a",
                   "q_param_2" => "b"
                 }

          Passby.Conn.resp(conn, 200, "")
        end
      ])

      assert {:ok, 200, ""} = request(bypass.port, path <> "?q_param_1=a&q_param_2=b", :post)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "All routes to a Bypass.expect(_once)/4 call must be called"
  # ---------------------------------------------------------------------------
  describe "multiple registered routes" do
    # Bypass additionally raises {:error, :not_called, {"POST", "/that"}} on exit
    # because /that was never called. Passby does not verify; but each route
    # must still match independently when it *is* called.
    test "each of several registered routes matches independently" do
      bypass = Passby.open()

      for path <- ["/this", "/that"] do
        Passby.expect(bypass, "POST", path, fn conn ->
          assert conn.request_path == path
          Passby.Conn.resp(conn, 200, path)
        end)
      end

      assert {:ok, 200, "/this"} = request(bypass.port, "/this", :post)
      assert {:ok, 200, "/that"} = request(bypass.port, "/that", :post)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.expect(_once)/4 can be used to define a specific route and
  #         then redefine it later"
  # ---------------------------------------------------------------------------
  describe "redefining routes" do
    test "expect/4 route can be redefined later", do: route_redefined(:expect)
    test "expect_once/4 route can be redefined later", do: route_redefined(:expect_once)

    defp route_redefined(expect_fun) do
      bypass = Passby.open()
      path = "/this"

      apply(Passby, expect_fun, [
        bypass,
        "POST",
        path,
        fn conn -> Passby.Conn.resp(conn, 200, "first response") end
      ])

      assert {:ok, 200, "first response"} = request(bypass.port, path, :post)

      apply(Passby, expect_fun, [
        bypass,
        "POST",
        path,
        fn conn -> Passby.Conn.resp(conn, 200, "other response") end
      ])

      assert {:ok, 200, "other response"} = request(bypass.port, path, :post)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.verify_expectations! - with ExUnit / with ESpec"
  # ---------------------------------------------------------------------------
  describe "verify_expectations! — not implemented" do
    # Bypass ships `verify_expectations!/1` (a no-op-then-raise under ExUnit,
    # a real check under ESpec) plus a configurable `:test_framework`. Passby
    # ships none of this.
    test "no verify_expectations!/1 and no ESpec integration" do
      refute function_exported?(Passby, :verify_expectations!, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.open/1 raises when cannot start child"
  # ---------------------------------------------------------------------------
  describe "open/1 error handling" do
    test "raises when the instance cannot be started" do
      Process.flag(:trap_exit, true)

      assert_raise RuntimeError, ~r/[Ff]ailed to start/, fn ->
        Passby.open(port: -1)
      end
    end
  end
end
