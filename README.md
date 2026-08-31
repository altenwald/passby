# Passby

[![Hex Package](https://img.shields.io/hexpm/v/passby.svg)](https://hex.pm/packages/passby)
[![Hex Docs](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/passby)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/altenwald/passby/blob/main/LICENSE)
[![CI](https://github.com/altenwald/passby/actions/workflows/elixir.yml/badge.svg)](https://github.com/altenwald/passby/actions/workflows/elixir.yml)
[![Paypal: Donation](https://img.shields.io/badge/paypal-donation-yellow)](https://www.paypal.com/donate/?hosted_button_id=XK6Z5XATN77L2)
[![Patreon: Donation](https://img.shields.io/badge/patreon-donation-yellow)](https://www.patreon.com/altenwald)

A **100% Elixir, 0-dependency** mock HTTP server designed for testing HTTP clients and integrations.

`Passby` is a lightweight, drop-in replacement for [`Bypass`](https://github.com/pspdfkit-labs/bypass). It provides the exact same API and semantics without dragging in `plug`, `plug_cowboy`, `cowboy`, `cowlib`, `ranch`, or `cowboy_telemetry`.

---

## Features

- **0 Runtime Dependencies**: Built entirely on standard Erlang/OTP (`:gen_tcp`, `:inet`, `:erlang.decode_packet`) and standard Elixir.
- **Drop-in Bypass API**: Identical function signatures (`open/1`, `expect/2,4`, `expect_once/2,4`, `stub/4`, `pass/1`, `down/1`, `up/1`).
- **Plug.Conn Compatibility**: `Passby.Conn` implements the same fields and helper functions (`resp/3`, `send_resp/1`, `get_req_header/2`, `put_resp_header/3`, `fetch_query_params/1`).
- **Params Parsing**: `conn.query_params` and `conn.params` are decoded exactly like `Bypass`/`Plug` do, including bracket notation (`filter[name]=Manuel` becomes `%{"filter" => %{"name" => "Manuel"}}`) and lists (`tags[]=a&tags[]=b`).
- **Route Patterns**: paths accept `:param` segments (`/users/:id`); captured values land in `conn.path_params` and are merged into `conn.params`, just like `Bypass`.
- **Concurrent & Isolated**: Each test can spin up its own instance on an ephemeral dynamic port.
- **Outage Simulation**: Easily simulate network disconnects and connection-refused errors with `Passby.down/1` and `Passby.up/1`.

---

## Installation

Add `passby` to your `mix.exs` dependencies for the `test` environment:

```elixir
def deps do
  [
    {:passby, "~> 0.2.0", only: :test}
  ]
end
```

---

## Quick Start

```elixir
defmodule MyClientTest do
  use ExUnit.Case, async: true

  setup do
    bypass = Passby.open()
    {:ok, bypass: bypass}
  end

  test "fetches user profile successfully", %{bypass: bypass} do
    Passby.expect_once(bypass, "GET", "/api/users/42", fn conn ->
      conn
      |> Passby.put_resp_header("content-type", "application/json")
      |> Passby.resp(200, ~s({"id": 42, "name": "Alice"}))
    end)

    assert {:ok, %{"name" => "Alice"}} = MyClient.get_user("#{bypass.url}/api/users/42")
  end
end
```

---

## Migrating from Bypass

Migrating from `Bypass` to `Passby` requires zero changes to test logic:

1. Replace `{:bypass, ...}` with `{:passby, "~> 0.2.0", only: :test}` in `mix.exs`.
2. Replace `Bypass.` calls with `Passby.`:

```elixir
# Before (Bypass)
setup do
  bypass = Bypass.open()
  {:ok, bypass: bypass}
end

# After (Passby)
setup do
  bypass = Passby.open()
  {:ok, bypass: bypass}
end
```

Handlers receive a `%Passby.Conn{}` struct with `query_params` and `params` already
populated (bracket notation and lists decoded just like `Bypass`). Calling
`Passby.Conn.fetch_query_params/1` again is a safe no-op, kept for `Plug.Conn` parity.

The struct works seamlessly with either `Passby.Conn` / `Passby` functions or `Plug.Conn` if you have Plug in your project:

```elixir
Passby.expect(bypass, "POST", "/messages", fn conn ->
  # Using Passby helpers:
  conn
  |> Passby.put_resp_header("content-type", "application/json")
  |> Passby.resp(201, ~s({"status": "created"}))

  # Or using Plug.Conn if available in your project:
  # Plug.Conn.resp(conn, 201, ~s({"status": "created"}))
end)
```

### Compatibility scope

`test/bypass_compat_test.exs` ports every scenario from the `Bypass` test suite.
The following API is supported with identical semantics:

`open/1`, `expect/2`, `expect/4`, `expect_once/2`, `expect_once/4`, `stub/4`,
`pass/1`, `down/1`, `up/1`, `:param` route patterns, `conn.params` /
`conn.query_params` / `conn.path_params` / `conn.port`, and route redefinition
(last definition wins).

The following `Bypass` behaviour is **not yet implemented** in `Passby`
(`test/bypass_compat_test.exs` covers each of these, asserting the current
behaviour):

| Bypass | Passby (current) |
| --- | --- |
| Automatic verification on test exit (`expect` raises if never called, `expect_once` raises if called twice) | No automatic verification; an unmet expectation is ignored and an unexpected request returns `500` |
| `verify_expectations!/1` and the `:test_framework` / ESpec integration | Not implemented |
| `expect/3` and `expect/5` with an exact expected request count | Not implemented (`expect` is "one or more", `expect_once` is "at most once") |
| `pass/1` marks the in-flight request as arrived | `pass/1` clears every expectation and stub |
| `down/1` blocks until in-flight handlers finish | `down/1` closes the listening socket immediately |

---

## Usage Patterns

### 1. Specific Request Expectations (`expect/4` and `expect_once/4`)

```elixir
# Matches only GET requests to /health
Passby.expect(bypass, "GET", "/health", fn conn ->
  Passby.resp(conn, 200, "OK")
end)

# Consumed after the first request
Passby.expect_once(bypass, "POST", "/checkout", fn conn ->
  assert conn.req_body =~ "item_123"
  Passby.resp(conn, 200, ~s({"order_id": 999}))
end)

# Route patterns: `:param` segments are captured into conn.path_params / conn.params
Passby.expect(bypass, "GET", "/users/:id", fn conn ->
  assert conn.path_params == %{"id" => "42"}
  Passby.resp(conn, 200, ~s({"id": #{conn.params["id"]}}))
end)
```

### 2. General Fallback Stubs (`stub/4`)

```elixir
Passby.stub(bypass, "GET", "/config", fn conn ->
  Passby.resp(conn, 200, ~s({"env": "test"}))
end)
```

### 3. Simulating Outages and Downtime (`down/1` and `up/1`)

```elixir
test "handles server outages gracefully", %{bypass: bypass} do
  Passby.down(bypass)

  url = Passby.url(bypass, "/api")
  assert {:error, :econnrefused} = MyClient.get(url)

  Passby.up(bypass)
  Passby.expect(bypass, "GET", "/api", fn conn ->
    Passby.resp(conn, 200, "recovered")
  end)

  assert {:ok, "recovered"} = MyClient.get(url)
end
```

---

## Quality & Compliance

Passby is fully tested, typed, and documented:

- 100% Doctor documentation & spec coverage
- Zero Dialyzer warnings
- Strict Credo style checks
- > 90% test coverage

To run the complete check suite locally:

```bash
mix check
```

---

## License

MIT License. Copyright (c) 2026 Altenwald Solutions, S.L.
