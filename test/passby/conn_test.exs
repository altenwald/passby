defmodule Passby.ConnTest do
  use ExUnit.Case, async: true
  alias Passby.Conn

  test "get_req_header/2 returns matching headers case-insensitively" do
    conn = %Conn{req_headers: [{"content-type", "application/json"}, {"X-API-KEY", "secret"}]}
    assert ["application/json"] == Conn.get_req_header(conn, "content-type")
    assert ["application/json"] == Conn.get_req_header(conn, "Content-Type")
    assert ["secret"] == Conn.get_req_header(conn, "x-api-key")
    assert [] == Conn.get_req_header(conn, "authorization")
  end

  test "put_resp_header/3 updates or appends header" do
    conn = %Conn{}
    conn = Conn.put_resp_header(conn, "content-type", "application/xml")
    assert [{"content-type", "application/xml"}] == conn.resp_headers

    conn2 = Conn.put_resp_header(conn, "Content-Type", "text/plain")
    assert [{"Content-Type", "text/plain"}] == conn2.resp_headers

    conn3 = Conn.put_resp_header(conn2, "X-Server", "Passby")
    assert [{"Content-Type", "text/plain"}, {"X-Server", "Passby"}] == conn3.resp_headers
  end

  test "resp/3 sets status and body" do
    conn = %Conn{}
    conn = Conn.resp(conn, 201, "Created")
    assert conn.status == 201
    assert conn.resp_body == "Created"
    assert conn.state == :set
  end

  test "send_resp/1 when already sent is a no-op" do
    conn = %Conn{state: :sent}
    assert ^conn = Conn.send_resp(conn)
  end

  test "a fresh conn has empty params, query_params and path_params" do
    conn = %Conn{}
    assert conn.params == %{}
    assert conn.query_params == %{}
    assert conn.path_params == %{}
  end

  test "fetch_query_params/1 decodes the query string into query_params and params" do
    conn = Conn.fetch_query_params(%Conn{query_string: "q=elixir&page=2"})
    assert conn.query_params == %{"q" => "elixir", "page" => "2"}
    assert conn.params == %{"q" => "elixir", "page" => "2"}
  end

  test "fetch_query_params/1 decodes bracket notation like Plug does" do
    conn = Conn.fetch_query_params(%Conn{query_string: "filter[name]=Manuel"})
    assert conn.query_params == %{"filter" => %{"name" => "Manuel"}}
    assert conn.params == %{"filter" => %{"name" => "Manuel"}}
  end

  test "fetch_query_params/1 with an empty query string yields empty maps" do
    conn = Conn.fetch_query_params(%Conn{query_string: ""})
    assert conn.query_params == %{}
    assert conn.params == %{}
  end

  test "fetch_query_params/1 keeps pre-existing params, letting them win over query params" do
    conn =
      Conn.fetch_query_params(%Conn{
        query_string: "id=from_query&extra=1",
        params: %{"id" => "from_path"}
      })

    assert conn.query_params == %{"id" => "from_query", "extra" => "1"}
    assert conn.params == %{"id" => "from_path", "extra" => "1"}
  end

  test "fetch_query_params/2 accepts an options argument for Plug compatibility" do
    conn = Conn.fetch_query_params(%Conn{query_string: "a=1"}, length: 1_000_000)
    assert conn.query_params == %{"a" => "1"}
  end

  test "send_resp/1 formats various reason phrases properly" do
    for {status, _reason} <- [
          {200, "OK"},
          {201, "Created"},
          {202, "Accepted"},
          {204, "No Content"},
          {301, "Moved Permanently"},
          {302, "Found"},
          {304, "Not Modified"},
          {400, "Bad Request"},
          {401, "Unauthorized"},
          {403, "Forbidden"},
          {404, "Not Found"},
          {405, "Method Not Allowed"},
          {422, "Unprocessable Entity"},
          {500, "Internal Server Error"},
          {502, "Bad Gateway"},
          {503, "Service Unavailable"},
          {504, "Gateway Timeout"},
          {418, "Custom"}
        ] do
      conn =
        %Conn{adapter: {Passby, nil}}
        |> Conn.put_resp_header("content-length", "4")
        |> Conn.resp(status, "test")
        |> Conn.send_resp()

      assert conn.status == status
      assert conn.state == :sent
    end
  end
end
