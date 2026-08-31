defmodule PassbyTest do
  use ExUnit.Case, async: true

  setup do
    :inets.start()
    :ok
  end

  defp http_get(url, headers \\ []) do
    char_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
    :httpc.request(:get, {to_charlist(url), char_headers}, [], [])
  end

  defp http_post(url, body, content_type \\ "text/plain", headers \\ []) do
    char_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    :httpc.request(
      :post,
      {to_charlist(url), char_headers, to_charlist(content_type), body},
      [],
      []
    )
  end

  test "starts an instance on an ephemeral port" do
    bypass = Passby.open()
    assert is_integer(bypass.port)
    assert bypass.port > 0
    assert is_pid(bypass.pid)
    assert bypass.url == "http://127.0.0.1:#{bypass.port}"
    assert Passby.url(bypass) == "http://127.0.0.1:#{bypass.port}"
    assert Passby.url(bypass, "/api/users/42") == "http://127.0.0.1:#{bypass.port}/api/users/42"
    assert Passby.url(bypass, "api/users/42") == "http://127.0.0.1:#{bypass.port}/api/users/42"
  end

  test "starts an instance with custom bind_address" do
    bypass = Passby.open(bind_address: {127, 0, 0, 1})
    assert bypass.url == "http://127.0.0.1:#{bypass.port}"
  end

  test "starts an instance on a specific port" do
    # Pick a random high port
    {:ok, temp} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(temp)
    :gen_tcp.close(temp)

    bypass = Passby.open(port: port)
    assert bypass.port == port
  end

  test "expect/2 matches any request" do
    bypass = Passby.open()

    Passby.expect(bypass, fn conn ->
      Passby.Conn.resp(conn, 200, "general response")
    end)

    url = "http://127.0.0.1:#{bypass.port}/any/path"
    assert {:ok, {{_, 200, _}, _, ~c"general response"}} = http_get(url)
  end

  test "expect/4 matches specific method and path" do
    bypass = Passby.open()

    Passby.expect(bypass, "POST", "/api/users", fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/users"
      assert conn.path_info == ["api", "users"]
      assert conn.req_body == ~s({"name":"John"})
      Passby.Conn.resp(conn, 201, ~s({"id":1}))
    end)

    url = "http://127.0.0.1:#{bypass.port}/api/users"

    assert {:ok, {{_, 201, _}, _, ~c"{\"id\":1}"}} =
             http_post(url, ~s({"name":"John"}), "application/json")
  end

  test "expect/4 accepts atom method" do
    bypass = Passby.open()

    Passby.expect(bypass, :post, "/api/test", fn conn ->
      Passby.Conn.resp(conn, 200, "atom ok")
    end)

    url = "http://127.0.0.1:#{bypass.port}/api/test"
    assert {:ok, {{_, 200, _}, _, ~c"atom ok"}} = http_post(url, "test")
  end

  test "expect_once/2 is consumed after first request" do
    bypass = Passby.open()

    Passby.expect_once(bypass, fn conn ->
      Passby.Conn.resp(conn, 200, "first")
    end)

    Passby.expect(bypass, fn conn ->
      Passby.Conn.resp(conn, 200, "subsequent")
    end)

    url = "http://127.0.0.1:#{bypass.port}/test"

    assert {:ok, {{_, 200, _}, _, ~c"first"}} = http_get(url)
    assert {:ok, {{_, 200, _}, _, ~c"subsequent"}} = http_get(url)
  end

  test "expect_once/4 matches correctly even when called in different order" do
    bypass = Passby.open()

    Passby.expect_once(bypass, "GET", "/a", fn conn -> Passby.Conn.resp(conn, 200, "A") end)
    Passby.expect_once(bypass, "GET", "/b", fn conn -> Passby.Conn.resp(conn, 200, "B") end)

    url_b = "http://127.0.0.1:#{bypass.port}/b"
    url_a = "http://127.0.0.1:#{bypass.port}/a"

    assert {:ok, {{_, 200, _}, _, ~c"B"}} = http_get(url_b)
    assert {:ok, {{_, 200, _}, _, ~c"A"}} = http_get(url_a)
  end

  test "expect_once/4 is consumed after first matching request" do
    bypass = Passby.open()

    Passby.expect_once(bypass, "POST", "/2.0/", fn conn ->
      Passby.Conn.resp(conn, 200, "login-response")
    end)

    Passby.stub(bypass, "POST", "/2.0/", fn conn ->
      Passby.Conn.resp(conn, 200, "stub-response")
    end)

    url = "http://127.0.0.1:#{bypass.port}/2.0/"

    assert {:ok, {{_, 200, _}, _, ~c"login-response"}} = http_post(url, "<xml/>")
    assert {:ok, {{_, 200, _}, _, ~c"stub-response"}} = http_post(url, "<xml/>")
  end

  test "stub/4 acts as fallback when expectations do not match" do
    bypass = Passby.open()

    Passby.stub(bypass, "GET", "/status", fn conn ->
      Passby.Conn.resp(conn, 200, "healthy")
    end)

    url = "http://127.0.0.1:#{bypass.port}/status"
    assert {:ok, {{_, 200, _}, _, ~c"healthy"}} = http_get(url)
  end

  test "pass/1 makes verification succeed without dropping the expectation" do
    bypass = Passby.open()

    Passby.expect_once(bypass, "GET", "/reset", fn conn ->
      Passby.Conn.resp(conn, 200, "served")
    end)

    Passby.pass(bypass)

    # The expectation was never called, yet verification passes.
    assert Passby.verify_expectations!(bypass) == :ok

    # And it is still installed.
    url = "http://127.0.0.1:#{bypass.port}/reset"
    assert {:ok, {{_, 200, _}, _, ~c"served"}} = http_get(url)
  end

  test "down/1 and up/1 simulate network outage and recovery" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/ping", fn conn ->
      Passby.Conn.resp(conn, 200, "pong")
    end)

    url = "http://127.0.0.1:#{bypass.port}/ping"
    assert {:ok, {{_, 200, _}, _, ~c"pong"}} = http_get(url)

    # Down the server
    assert :ok = Passby.down(bypass)
    # Re-downing when already down is a no-op
    assert :ok = Passby.down(bypass)

    # Request should fail with econnrefused
    assert {:error, {:failed_connect, _}} = http_get(url)

    # Bring it back up
    assert :ok = Passby.up(bypass)
    # Re-upping when already up is a no-op
    assert :ok = Passby.up(bypass)

    assert {:ok, {{_, 200, _}, _, ~c"pong"}} = http_get(url)
  end

  test "reads request headers case-insensitively" do
    bypass = Passby.open()

    Passby.expect(bypass, "POST", "/headers", fn conn ->
      assert ["sessionOpen"] == Passby.get_req_header(conn, "soapaction")
      assert ["sessionOpen"] == Passby.Conn.get_req_header(conn, "SoapAction")
      assert ["sessionOpen"] == Passby.Conn.get_req_header(conn, "SOAPACTION")
      assert [] == Passby.get_req_header(conn, "non-existent")
      Passby.Conn.resp(conn, 200, "headers ok")
    end)

    url = "http://127.0.0.1:#{bypass.port}/headers"
    headers = [{"SoapAction", "sessionOpen"}]

    assert {:ok, {{_, 200, _}, _, ~c"headers ok"}} =
             http_post(url, "payload", "text/xml", headers)
  end

  test "sets custom response headers and status codes" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/custom", fn conn ->
      conn
      |> Passby.put_resp_header("x-custom-header", "hemdal-123")
      |> Passby.put_resp_header("content-type", "application/json")
      |> Passby.resp(404, ~s({"error":"not found"}))
    end)

    url = "http://127.0.0.1:#{bypass.port}/custom"
    assert {:ok, {{_, 404, _}, resp_headers, ~c"{\"error\":\"not found\"}"}} = http_get(url)

    headers_map = Map.new(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end)
    assert headers_map["x-custom-header"] == "hemdal-123"
    assert headers_map["content-type"] == "application/json"
  end

  test "supports send_resp/1 and send_resp/3 explicit sending" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/send-explicit", fn conn ->
      Passby.send_resp(conn, 202, "Accepted explicitly")
    end)

    url = "http://127.0.0.1:#{bypass.port}/send-explicit"
    assert {:ok, {{_, 202, _}, _, ~c"Accepted explicitly"}} = http_get(url)
  end

  test "parses query strings and path segments" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/search", fn conn ->
      assert conn.query_string == "q=elixir&page=2"
      assert conn.path_info == ["search"]
      Passby.Conn.resp(conn, 200, "found")
    end)

    url = "http://127.0.0.1:#{bypass.port}/search?q=elixir&page=2"
    assert {:ok, {{_, 200, _}, _, ~c"found"}} = http_get(url)
  end

  test "decodes bracket-notation query params like Bypass/Plug" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/search", fn conn ->
      assert conn.params == %{"filter" => %{"name" => "Manuel"}, "page" => "2"}
      assert conn.query_params == %{"filter" => %{"name" => "Manuel"}, "page" => "2"}
      Passby.Conn.resp(conn, 200, "found")
    end)

    url = "http://127.0.0.1:#{bypass.port}/search?filter%5Bname%5D=Manuel&page=2"
    assert {:ok, {{_, 200, _}, _, ~c"found"}} = http_get(url)
  end

  test "Passby.fetch_query_params/1 is available as a delegate" do
    conn = Passby.fetch_query_params(%Passby.Conn{query_string: "a[b]=c"})
    assert conn.params == %{"a" => %{"b" => "c"}}
  end

  test "expect/4 matches route patterns and captures path params like Bypass" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/users/:id", fn conn ->
      assert conn.path_params == %{"id" => "42"}
      assert conn.params == %{"id" => "42"}
      Passby.Conn.resp(conn, 200, "user 42")
    end)

    url = "http://127.0.0.1:#{bypass.port}/users/42"
    assert {:ok, {{_, 200, _}, _, ~c"user 42"}} = http_get(url)
  end

  test "captures multiple path params in a single route" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/users/:user_id/posts/:post_id", fn conn ->
      assert conn.path_params == %{"user_id" => "7", "post_id" => "99"}
      Passby.Conn.resp(conn, 200, "ok")
    end)

    url = "http://127.0.0.1:#{bypass.port}/users/7/posts/99"
    assert {:ok, {{_, 200, _}, _, ~c"ok"}} = http_get(url)
  end

  test "path params and query params are merged, path params winning on conflict" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/users/:id", fn conn ->
      assert conn.path_params == %{"id" => "42"}
      assert conn.query_params == %{"id" => "ignored", "page" => "2"}
      assert conn.params == %{"id" => "42", "page" => "2"}
      Passby.Conn.resp(conn, 200, "ok")
    end)

    url = "http://127.0.0.1:#{bypass.port}/users/42?id=ignored&page=2"
    assert {:ok, {{_, 200, _}, _, ~c"ok"}} = http_get(url)
  end

  test "a route pattern does not match when the segment count differs" do
    bypass = Passby.open(verify: false)

    Passby.expect(bypass, "GET", "/users/:id", fn conn ->
      Passby.Conn.resp(conn, 200, "matched")
    end)

    url = "http://127.0.0.1:#{bypass.port}/users/42/extra"
    assert {:ok, {{_, 500, _}, _, body}} = http_get(url)
    assert to_string(body) =~ "No expectation"
  end

  test "static routes still match exactly and expose empty path params" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/health", fn conn ->
      assert conn.path_params == %{}
      Passby.Conn.resp(conn, 200, "OK")
    end)

    url = "http://127.0.0.1:#{bypass.port}/health"
    assert {:ok, {{_, 200, _}, _, ~c"OK"}} = http_get(url)
  end

  test "handles large request bodies properly" do
    bypass = Passby.open()
    large_body = String.duplicate("abcdef123456", 5_000)

    Passby.expect(bypass, "POST", "/upload", fn conn ->
      assert conn.req_body == large_body
      Passby.Conn.resp(conn, 200, "uploaded")
    end)

    url = "http://127.0.0.1:#{bypass.port}/upload"
    assert {:ok, {{_, 200, _}, _, ~c"uploaded"}} = http_post(url, large_body)
  end

  test "handles handler exceptions gracefully by responding with 500" do
    bypass = Passby.open(verify: false)

    Passby.expect(bypass, "GET", "/crash", fn _conn ->
      raise "intentional crash in test"
    end)

    url = "http://127.0.0.1:#{bypass.port}/crash"
    assert {:ok, {{_, 500, _}, _, ~c"Internal Server Error in Passby Handler"}} = http_get(url)

    # The client saw a 500, but the error is not swallowed: it is re-raised,
    # with its original stacktrace, when the expectations are verified.
    assert_raise RuntimeError, "intentional crash in test", fn ->
      Passby.verify_expectations!(bypass)
    end
  end

  test "returns 500 when no expectation matches" do
    bypass = Passby.open(verify: false)

    url = "http://127.0.0.1:#{bypass.port}/unmatched"
    assert {:ok, {{_, 500, _}, _, body}} = http_get(url)
    assert to_string(body) =~ "No expectation or stub set in Passby"
  end

  test "handler returning a map with status and resp_body" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/map-resp", fn _conn ->
      %{status: 200, resp_body: "map body", resp_headers: [{"content-type", "text/plain"}]}
    end)

    url = "http://127.0.0.1:#{bypass.port}/map-resp"
    assert {:ok, {{_, 200, _}, _, ~c"map body"}} = http_get(url)
  end

  test "handler returning non-conn fallback" do
    bypass = Passby.open()

    Passby.expect(bypass, "GET", "/other-resp", fn _conn ->
      :ok
    end)

    url = "http://127.0.0.1:#{bypass.port}/other-resp"
    assert {:ok, {{_, 200, _}, _, ~c"OK"}} = http_get(url)
  end

  test "Passby top-level delegates work identically to Passby.Conn" do
    conn = %Passby.Conn{req_headers: [{"content-type", "application/json"}]}
    assert ["application/json"] == Passby.get_req_header(conn, "content-type")

    conn = Passby.put_resp_header(conn, "server", "passby")

    assert [{"content-type", "text/plain; charset=utf-8"}, {"server", "passby"}] ==
             conn.resp_headers

    conn = Passby.resp(conn, 200, "hello")
    assert conn.status == 200
    assert conn.resp_body == "hello"

    conn = Passby.send_resp(conn)
    assert conn.state == :sent

    conn2 = %Passby.Conn{}
    conn2 = Passby.send_resp(conn2, 201, "created")
    assert conn2.status == 201
    assert conn2.state == :sent
  end

  test "handles handler throw and exit gracefully" do
    bypass = Passby.open(verify: false)

    Passby.expect(bypass, "GET", "/throw", fn _conn ->
      throw(:intentional_throw)
    end)

    url = "http://127.0.0.1:#{bypass.port}/throw"
    assert {:ok, {{_, 500, _}, _, ~c"Internal Server Error in Passby Handler"}} = http_get(url)

    assert catch_throw(Passby.verify_expectations!(bypass)) == :intentional_throw
  end

  test "handles a handler exiting" do
    bypass = Passby.open(verify: false)

    Passby.expect(bypass, "GET", "/exit", fn _conn -> exit(:intentional_exit) end)

    url = "http://127.0.0.1:#{bypass.port}/exit"
    assert {:ok, {{_, 500, _}, _, ~c"Internal Server Error in Passby Handler"}} = http_get(url)

    assert catch_exit(Passby.verify_expectations!(bypass)) == :intentional_exit
  end

  test "handles client connecting and closing socket immediately" do
    bypass = Passby.open()
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", bypass.port, [:binary, active: false])
    :gen_tcp.close(client)

    Passby.expect(bypass, "GET", "/alive", fn conn ->
      Passby.Conn.resp(conn, 200, "alive")
    end)

    url = "http://127.0.0.1:#{bypass.port}/alive"
    assert {:ok, {{_, 200, _}, _, ~c"alive"}} = http_get(url)
  end

  test "fails gracefully on invalid listen port" do
    Process.flag(:trap_exit, true)
    assert {:error, :badarg} = Passby.Instance.start_link(port: -1)
  end

  test "matches method-only and path-only expectations" do
    bypass = Passby.open()

    Passby.expect(bypass, "POST", nil, fn conn ->
      Passby.Conn.resp(conn, 200, "post-any-path")
    end)

    Passby.expect(bypass, nil, "/any-method", fn conn ->
      Passby.Conn.resp(conn, 200, "any-method-ok")
    end)

    url_post = "http://127.0.0.1:#{bypass.port}/custom/route"
    assert {:ok, {{_, 200, _}, _, ~c"post-any-path"}} = http_post(url_post, "data")

    url_get = "http://127.0.0.1:#{bypass.port}/any-method"
    assert {:ok, {{_, 200, _}, _, ~c"any-method-ok"}} = http_get(url_get)
  end

  test "multiple stubs fall through correctly" do
    bypass = Passby.open()

    Passby.stub(bypass, "POST", "/different", fn conn ->
      Passby.Conn.resp(conn, 200, "diff")
    end)

    Passby.stub(bypass, "GET", "/stubbed", fn conn ->
      Passby.Conn.resp(conn, 200, "stubbed-ok")
    end)

    url = "http://127.0.0.1:#{bypass.port}/stubbed"
    assert {:ok, {{_, 200, _}, _, ~c"stubbed-ok"}} = http_get(url)
  end

  test "terminates instance process cleanly" do
    # Stopping the instance by hand means opting out of verification: an
    # instance that is gone can no longer report on its expectations.
    bypass = Passby.open(verify: false)
    assert Process.alive?(bypass.pid)
    GenServer.stop(bypass.pid)
    refute Process.alive?(bypass.pid)
  end
end
