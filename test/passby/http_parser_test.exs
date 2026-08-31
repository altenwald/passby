defmodule Passby.HttpParserTest do
  use ExUnit.Case, async: true
  alias Passby.HttpParser

  test "parses full HTTP/1.1 request from socket" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      res = HttpParser.parse_request(client)
      send(parent, {:parsed, res})
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    raw_req =
      "POST /api/test?foo=bar HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nping"

    :ok = :gen_tcp.send(client, raw_req)
    :gen_tcp.close(client)

    assert_receive {:parsed, {:ok, conn}}, 1000
    assert conn.method == "POST"
    assert conn.request_path == "/api/test"
    assert conn.query_string == "foo=bar"
    assert conn.path_info == ["api", "test"]
    assert conn.req_body == "ping"
    assert conn.query_params == %{"foo" => "bar"}
    assert conn.params == %{"foo" => "bar"}
  end

  test "auto-populates query_params and params with bracket notation decoded" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      res = HttpParser.parse_request(client)
      send(parent, {:parsed, res})
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    raw_req =
      "GET /search?filter[name]=Manuel&tags[]=a&tags[]=b HTTP/1.1\r\nHost: localhost\r\n\r\n"

    :ok = :gen_tcp.send(client, raw_req)
    :gen_tcp.close(client)

    assert_receive {:parsed, {:ok, conn}}, 1000
    assert conn.query_params == %{"filter" => %{"name" => "Manuel"}, "tags" => ["a", "b"]}
    assert conn.params == %{"filter" => %{"name" => "Manuel"}, "tags" => ["a", "b"]}
  end

  test "parses request sent across multiple TCP chunks" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      res = HttpParser.parse_request(client)
      send(parent, {:parsed, res})
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(client, "GET /chunked")
    :timer.sleep(10)
    :ok = :gen_tcp.send(client, " HTTP/1.1\r\n")
    :timer.sleep(10)
    :ok = :gen_tcp.send(client, "Host: 127.0.0.1\r\n")
    :timer.sleep(10)
    :ok = :gen_tcp.send(client, "Content-Length: 3\r\n\r\n")
    :timer.sleep(10)
    :ok = :gen_tcp.send(client, "foo")
    :gen_tcp.close(client)

    assert_receive {:parsed, {:ok, conn}}, 1000
    assert conn.method == "GET"
    assert conn.request_path == "/chunked"
    assert conn.req_body == "foo"
  end

  test "handles client disconnect / closed socket" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      res = HttpParser.parse_request(client)
      send(parent, {:parsed, res})
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :gen_tcp.close(client)

    assert_receive {:parsed, {:error, :closed}}, 1000
  end

  test "parses request with initial buffer and invalid content length" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)

      initial_buffer =
        "CUSTOM /initial HTTP/1.1\r\nHost: localhost\r\nContent-Length: invalid\r\n\r\n"

      res = HttpParser.parse_request(client, initial_buffer)
      send(parent, {:parsed, res})
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :gen_tcp.close(client)

    assert_receive {:parsed, {:ok, conn}}, 1000
    assert conn.method == "CUSTOM"
    assert conn.request_path == "/initial"
    assert conn.req_body == ""
  end

  test "parses absolute URI request line" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)

      initial_buffer =
        "GET http://localhost:8080/proxied/path?key=val HTTP/1.1\r\nHost: localhost\r\n\r\n"

      res = HttpParser.parse_request(client, initial_buffer)
      send(parent, {:parsed, res})
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :gen_tcp.close(client)

    assert_receive {:parsed, {:ok, conn}}, 1000
    assert conn.method == "GET"
    assert conn.request_path == "/proxied/path"
    assert conn.query_string == "key=val"
  end

  test "handles malformed request line" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      res = HttpParser.parse_request(client)
      send(parent, {:parsed, res})
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(client, "THIS IS NOT HTTP AT ALL\r\n\r\n")
    :gen_tcp.close(client)

    assert_receive {:parsed, {:error, _}}, 1000
  end

  test "handles malformed header line" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen)
      res = HttpParser.parse_request(client)
      send(parent, {:parsed, res})
      :gen_tcp.close(client)
      :gen_tcp.close(listen)
    end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(client, "GET / HTTP/1.1\r\nBad Header Without Colon\r\n\r\n")
    :gen_tcp.close(client)

    assert_receive {:parsed, {:error, _}}, 1000
  end
end
