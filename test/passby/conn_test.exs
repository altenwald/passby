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
