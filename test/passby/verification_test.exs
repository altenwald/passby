defmodule Passby.VerificationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  setup do
    :inets.start()
    :ok
  end

  defp get(port, path) do
    url = ~c"http://127.0.0.1:#{port}#{path}"

    case :httpc.request(:get, {url, []}, [], []) do
      {:ok, {{_http, status, _reason}, _headers, body}} -> {:ok, status, to_string(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  describe "lifecycle" do
    test "an armed instance outlives the test process, so it can still be verified" do
      bypass = Passby.open()
      Passby.stub(bypass, "GET", "/x", &Passby.Conn.resp(&1, 200, ""))

      # on_exit callbacks run in reverse registration order, so this one runs
      # after the test process is gone but before the callback Passby.open/1
      # registered.
      ExUnit.Callbacks.on_exit(fn ->
        assert Process.alive?(bypass.pid)
      end)
    end

    test "an unverified instance dies with the process that opened it" do
      parent = self()

      opener =
        spawn(fn ->
          send(parent, {:opened, Passby.open(verify: false)})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:opened, bypass}
      ref = Process.monitor(bypass.pid)

      send(opener, :stop)

      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000
    end

    test "opening outside a test process does not raise" do
      parent = self()

      spawn(fn -> send(parent, {:opened, Passby.open()}) end)

      assert_receive {:opened, %Passby{} = bypass}
      assert is_integer(bypass.port)
    end
  end

  describe "what is verified" do
    test "stubs are never verified" do
      bypass = Passby.open()
      Passby.stub(bypass, "GET", "/never", &Passby.Conn.resp(&1, 200, ""))

      assert Passby.verify_expectations!(bypass) == :ok
    end

    test "a met expectation verifies" do
      bypass = Passby.open()
      Passby.expect_once(bypass, "GET", "/once", &Passby.Conn.resp(&1, 200, "ok"))

      assert {:ok, 200, "ok"} = get(bypass.port, "/once")
      assert Passby.verify_expectations!(bypass) == :ok
    end

    test "a route is verified per method, not per path alone" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, "POST", "/thing", &Passby.Conn.resp(&1, 200, ""))

      assert {:ok, 500, _body} = get(bypass.port, "/thing")

      assert_raise ExUnit.AssertionError,
                   ~r|Passby got an HTTP request but wasn't expecting one at GET /thing|,
                   fn -> Passby.verify_expectations!(bypass) end
    end

    test "verifying twice is stable" do
      bypass = Passby.open(verify: false)
      Passby.expect(bypass, "GET", "/x", &Passby.Conn.resp(&1, 200, ""))

      for _ <- 1..2 do
        assert_raise ExUnit.AssertionError, fn -> Passby.verify_expectations!(bypass) end
      end
    end
  end

  describe "handlers still in flight" do
    test "verification waits for a handler that has not finished" do
      bypass = Passby.open(verify: false)
      test_pid = self()

      Passby.expect(bypass, "GET", "/slow", fn _conn ->
        send(test_pid, :handler_started)
        Process.sleep(100)
        raise "late failure"
      end)

      spawn(fn -> get(bypass.port, "/slow") end)
      assert_receive :handler_started

      capture_log(fn ->
        assert_raise RuntimeError, "late failure", fn ->
          Passby.verify_expectations!(bypass)
        end
      end)
    end

    test "a handler killed from the outside fails verification" do
      bypass = Passby.open(verify: false)
      test_pid = self()

      Passby.expect(bypass, "GET", "/hang", fn conn ->
        send(test_pid, {:handler, self()})
        Process.sleep(:infinity)
        conn
      end)

      spawn(fn -> get(bypass.port, "/hang") end)
      assert_receive {:handler, handler}

      # The request was admitted and counted, so without noticing the handler
      # died the expectation would look satisfied.
      Process.exit(handler, :kill)

      assert catch_exit(Passby.verify_expectations!(bypass)) == :killed
    end

    test "pass/1 releases the handlers still in flight" do
      bypass = Passby.open(verify: false)
      test_pid = self()

      Passby.expect(bypass, "GET", "/hang", fn conn ->
        send(test_pid, :handler_started)
        Process.sleep(:infinity)
        conn
      end)

      spawn(fn -> get(bypass.port, "/hang") end)
      assert_receive :handler_started

      Passby.pass(bypass)

      # Would block until the handler finished, which is never, without pass/1.
      assert Passby.verify_expectations!(bypass) == :ok
    end
  end

  describe "an instance that is gone" do
    test "is reported rather than silently passing" do
      bypass = Passby.open(verify: false)
      Passby.expect_once(bypass, "GET", "/x", &Passby.Conn.resp(&1, 200, ""))

      GenServer.stop(bypass.pid)

      assert_raise ExUnit.AssertionError, ~r/no longer running/, fn ->
        Passby.verify_expectations!(bypass)
      end
    end
  end

  describe "handler errors" do
    test "are re-raised with the handler's own stacktrace" do
      bypass = Passby.open(verify: false)

      Passby.expect(bypass, "GET", "/boom", fn _conn -> raise ArgumentError, "boom" end)

      capture_log(fn ->
        assert {:ok, 500, _body} = get(bypass.port, "/boom")
      end)

      stacktrace =
        try do
          Passby.verify_expectations!(bypass)
          flunk("expected the handler error to be re-raised")
        rescue
          ArgumentError -> __STACKTRACE__
        end

      assert Enum.any?(stacktrace, fn {module, _fun, _arity, _location} ->
               module == __MODULE__
             end)
    end

    test "do not mask an expectation that was never called" do
      bypass = Passby.open(verify: false)

      Passby.expect(bypass, "GET", "/boom", fn _conn -> raise ArgumentError, "boom" end)
      Passby.expect(bypass, "GET", "/never", &Passby.Conn.resp(&1, 200, ""))

      capture_log(fn ->
        assert {:ok, 500, _body} = get(bypass.port, "/boom")
      end)

      assert_raise ExUnit.AssertionError,
                   ~r|No HTTP request arrived at Passby at GET /never|,
                   fn -> Passby.verify_expectations!(bypass) end
    end
  end
end
