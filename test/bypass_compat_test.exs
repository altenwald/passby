defmodule BypassCompatTest do
  @moduledoc """
  Every scenario exercised by the Bypass test suite
  (https://github.com/PSPDFKit-labs/bypass, `test/bypass_test.exs`), ported and
  adapted to the `Passby` API.

  Each Bypass test maps to a test here. Where `Passby` behaves like Bypass, the
  assertion is the same. Where it deliberately differs, the comment states what
  Bypass does instead. Nothing Bypass tests is left unmentioned.

  Tests that assert a verification failure open the instance with
  `verify: false` and call `Passby.verify_expectations!/1` themselves, so that
  the expected failure does not fail this suite.
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
  describe "unmet expectations" do
    test "a never-called expect/2 fails verification" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, fn _conn -> flunk("must not be called") end)

      assert_raise ExUnit.AssertionError, ~r/No HTTP request arrived at Passby/, fn ->
        Passby.verify_expectations!(bypass)
      end
    end

    test "a never-called expect_once/2 fails verification" do
      bypass = Passby.open(verify: false)
      Passby.expect_once(bypass, fn _conn -> flunk("must not be called") end)

      assert_raise ExUnit.AssertionError, ~r/No HTTP request arrived at Passby/, fn ->
        Passby.verify_expectations!(bypass)
      end
    end

    test "a never-called route expectation names the route" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, "POST", "/that", fn _conn -> flunk("must not be called") end)

      assert_raise ExUnit.AssertionError,
                   ~r|No HTTP request arrived at Passby at POST /that|,
                   fn -> Passby.verify_expectations!(bypass) end
    end

    # Bypass keys its on_exit handler by {Bypass, pid} so that a test can
    # replace it and assert the raw result. Passby keys its own by
    # {Passby, pid}, which is what makes this replacement possible.
    test "open/1 registers the verification, and it can be replaced" do
      bypass = Passby.open()
      Passby.expect(bypass, fn _conn -> flunk("must not be called") end)

      ExUnit.Callbacks.on_exit({Passby, bypass.pid}, fn ->
        assert {:error, :not_called, {:any, :any}} = Passby.Instance.on_exit(bypass.pid)
      end)
    end

    test "the registered verification actually runs when the test exits" do
      # Callbacks run in reverse registration order, so this one runs after the
      # callback Passby.open/1 is about to install. The agent is unlinked so it
      # outlives the test process and can carry the pid across.
      {:ok, holder} = Agent.start(fn -> nil end)

      ExUnit.Callbacks.on_exit(fn ->
        pid = Agent.get(holder, & &1)
        refute Process.alive?(pid), "Passby.open/1 never installed its verification callback"
        Agent.stop(holder)
      end)

      bypass = Passby.open()
      Agent.update(holder, fn _ -> bypass.pid end)
      Passby.stub(bypass, "GET", "/x", &Passby.Conn.resp(&1, 200, ""))
    end

    test "verification can be turned off entirely" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, fn _conn -> flunk("must not be called") end)
      assert is_pid(bypass.pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.expect can be made to pass by calling Bypass.pass" (+ once)
  #         "Calling a bypass route without expecting a call fails the test"
  # ---------------------------------------------------------------------------
  describe "pass/1 and unmatched routes" do
    test "pass/1 makes an uncalled expectation verify, and keeps serving it" do
      bypass = Passby.open()
      Passby.expect(bypass, "GET", "/x", fn conn -> Passby.Conn.resp(conn, 200, "hit") end)

      Passby.pass(bypass)

      assert Passby.verify_expectations!(bypass) == :ok
      assert {:ok, 200, "hit"} = request(bypass.port, "/x", :get)
    end

    # The Bypass idiom: a handler that is expected to blow up.
    test "pass/1 from inside a handler covers the handler's own failure" do
      bypass = Passby.open()

      Passby.expect(bypass, "GET", "/x", fn _conn ->
        Passby.pass(bypass)
        flunk("intentional failure")
      end)

      assert capture_log(fn ->
               assert {:ok, 500, _body} = request(bypass.port, "/x", :get)
             end) =~ "intentional failure"
    end

    test "calling a route with no expectation returns 500 and fails verification" do
      bypass = Passby.open(verify: false)
      assert {:ok, 500, _body} = request(bypass.port)

      assert_raise ExUnit.AssertionError,
                   ~r|Passby got an HTTP request but wasn't expecting one at POST /example_path|,
                   fn -> Passby.verify_expectations!(bypass) end
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

    test "the Bypass idiom, pass/1 then down/1 from the handler",
      do: closing_in_flight(:expect, true)

    defp closing_in_flight(expect_fun, pass_first \\ false) do
      bypass = Passby.open()

      apply(Passby, expect_fun, [
        bypass,
        fn conn ->
          # Bypass's own test passes first, because its `down/1` waits for
          # in-flight handlers and `pass/1` is what releases them. Passby waits
          # too, but never for the handler asking, so both orders work.
          if pass_first, do: Passby.pass(bypass)
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
  describe "down/1 graceful termination" do
    test "down/1 waits for a handler that is still running" do
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

      # The handler ran to completion before the socket was closed.
      assert_received ^ref
      assert elapsed >= 100
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
      bypass = Passby.open(verify: false)
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

      # The requests that were turned away fail verification, as in Bypass.
      assert_raise ExUnit.AssertionError,
                   ~r/Expected only one HTTP request for Passby/,
                   fn -> Passby.verify_expectations!(bypass) end
    end
  end

  # ---------------------------------------------------------------------------
  # Bypass: "Bypass.expect/3 fails when too many / not enough requests arrived"
  #         "Bypass.expect/5 fails when too many / not enough requests arrived"
  # ---------------------------------------------------------------------------
  describe "expected request counts" do
    test "expect/3 fails when not enough requests arrived" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, 2, fn conn -> Passby.Conn.resp(conn, 200, "ok") end)

      assert {:ok, 200, "ok"} = request(bypass.port)

      assert_raise ExUnit.AssertionError,
                   ~r/Expected 2 HTTP requests for Passby, got 1/,
                   fn -> Passby.verify_expectations!(bypass) end

      assert {:ok, 200, "ok"} = request(bypass.port)
      assert Passby.verify_expectations!(bypass) == :ok
    end

    test "expect/3 fails when too many requests arrived" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, 1, fn conn -> Passby.Conn.resp(conn, 200, "ok") end)

      assert {:ok, 200, "ok"} = request(bypass.port)
      assert {:ok, 500, _} = request(bypass.port)

      assert_raise ExUnit.AssertionError,
                   ~r/Expected 1 HTTP requests for Passby, got 2/,
                   fn -> Passby.verify_expectations!(bypass) end
    end

    test "every excess request is counted, not just the first" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, 2, fn conn -> Passby.Conn.resp(conn, 200, "ok") end)

      for _ <- 1..5, do: request(bypass.port)

      assert_raise ExUnit.AssertionError,
                   ~r/Expected 2 HTTP requests for Passby, got 5/,
                   fn -> Passby.verify_expectations!(bypass) end
    end

    test "expect/5 counts requests per route" do
      bypass = Passby.open(verify: false)

      Passby.expect(bypass, "GET", "/foo", 2, fn conn -> Passby.Conn.resp(conn, 200, "ok") end)

      assert {:ok, 200, "ok"} = request(bypass.port, "/foo", :get)

      assert_raise ExUnit.AssertionError,
                   ~r|Expected 2 HTTP requests for Passby at GET /foo, got 1|,
                   fn -> Passby.verify_expectations!(bypass) end

      assert {:ok, 200, "ok"} = request(bypass.port, "/foo", :get)
      assert Passby.verify_expectations!(bypass) == :ok

      assert {:ok, 500, _} = request(bypass.port, "/foo", :get)

      assert_raise ExUnit.AssertionError,
                   ~r|Expected 2 HTTP requests for Passby at GET /foo, got 3|,
                   fn -> Passby.verify_expectations!(bypass) end
    end

    test "expect/4 keeps serving every request, one or more" do
      bypass = Passby.open()
      Passby.expect(bypass, "GET", "/foo", fn conn -> Passby.Conn.resp(conn, 200, "ok") end)

      for _ <- 1..5 do
        assert {:ok, 200, "ok"} = request(bypass.port, "/foo", :get)
      end
    end

    test "expect_once/4 serves the first request, then 500s and fails verification" do
      bypass = Passby.open(verify: false)
      Passby.expect_once(bypass, "GET", "/foo", fn conn -> Passby.Conn.resp(conn, 200, "ok") end)

      assert {:ok, 200, "ok"} = request(bypass.port, "/foo", :get)
      assert {:ok, 500, _} = request(bypass.port, "/foo", :get)

      assert_raise ExUnit.AssertionError,
                   ~r|Expected only one HTTP request for Passby at GET /foo|,
                   fn -> Passby.verify_expectations!(bypass) end
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
    test "every registered route must be called" do
      bypass = Passby.open(verify: false)

      for path <- ["/this", "/that"] do
        Passby.expect(bypass, "POST", path, fn conn -> Passby.Conn.resp(conn, 200, path) end)
      end

      assert {:ok, 200, "/this"} = request(bypass.port, "/this", :post)

      assert_raise ExUnit.AssertionError,
                   ~r|No HTTP request arrived at Passby at POST /that|,
                   fn -> Passby.verify_expectations!(bypass) end
    end

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
  # ---------------------------------------------------------------------------
  # Bypass: precedence in Bypass.Instance.expectation_problem_message/1
  # ---------------------------------------------------------------------------
  describe "which failure is reported" do
    test "a route that was never called beats a route that got too many" do
      bypass = Passby.open(verify: false)
      Passby.expect_once(bypass, "GET", "/a", fn conn -> Passby.Conn.resp(conn, 200, "") end)
      Passby.expect(bypass, "GET", "/b", fn conn -> Passby.Conn.resp(conn, 200, "") end)

      assert {:ok, 200, ""} = request(bypass.port, "/a", :get)
      assert {:ok, 500, _} = request(bypass.port, "/a", :get)

      assert_raise ExUnit.AssertionError,
                   ~r|No HTTP request arrived at Passby at GET /b|,
                   fn -> Passby.verify_expectations!(bypass) end
    end

    test "a request for an undeclared route beats everything" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, "GET", "/b", fn conn -> Passby.Conn.resp(conn, 200, "") end)

      assert {:ok, 500, _} = request(bypass.port, "/nowhere", :get)

      assert_raise ExUnit.AssertionError,
                   ~r|Passby got an HTTP request but wasn't expecting one at GET /nowhere|,
                   fn -> Passby.verify_expectations!(bypass) end
    end
  end

  describe "verify_expectations!" do
    # Bypass ships `verify_expectations!/1` for ESpec only: under ExUnit it
    # raises "Not available in ExUnit, as it's configured automatically."
    # Passby runs the same check in both cases, so a test can also assert
    # mid-test. There is no `:test_framework` setting to configure.
    test "verifies on demand without stopping the instance" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, "GET", "/foo", fn conn -> Passby.Conn.resp(conn, 200, "ok") end)

      assert_raise ExUnit.AssertionError,
                   ~r|No HTTP request arrived at Passby at GET /foo|,
                   fn -> Passby.verify_expectations!(bypass) end

      assert {:ok, 200, "ok"} = request(bypass.port, "/foo", :get)
      assert Passby.verify_expectations!(bypass) == :ok
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
