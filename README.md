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
- **Drop-in Bypass API**: Identical function signatures (`open/1`, `expect/2,3,4,5`, `expect_once/2,4`, `stub/4`, `pass/1`, `down/1`, `up/1`, `verify_expectations!/1`).
- **Automatic Verification**: Expectations are checked when the test exits, so an expectation that never receives its request fails the test instead of passing silently. Errors raised inside a handler are re-raised too, rather than being swallowed by the `500` the client receives.
- **Plug.Conn Compatibility**: `Passby.Conn` implements the same fields and helper functions (`resp/3`, `send_resp/1`, `get_req_header/2`, `put_resp_header/3`, `fetch_query_params/1`).
- **Params Parsing**: `conn.query_params` and `conn.params` are decoded exactly like `Bypass`/`Plug` do, including bracket notation (`filter[name]=Manuel` becomes `%{"filter" => %{"name" => "Manuel"}}`) and lists (`tags[]=a&tags[]=b`).
- **Route Patterns**: paths accept `:param` segments (`/users/:id`); captured values land in `conn.path_params` and are merged into `conn.params`, just like `Bypass`.
- **Concurrent & Isolated**: Each test can spin up its own instance on an ephemeral dynamic port.
- **Outage Simulation**: Easily simulate network disconnects and connection-refused errors with `Passby.down/1` and `Passby.up/1`. `down/1` waits for the handlers still in flight, so closing the socket cannot truncate a response the client is still reading.

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

## Verification

Expectations are verified when the test that opened the instance finishes:

| Declaration | Requests it must receive |
| --- | --- |
| `expect/2,4` | one or more |
| `expect_once/2,4` | exactly one |
| `expect/3,5` | exactly the given count |
| `stub/4` | any number, including none |

A request matching no expectation answers `500` and fails the test, and an
error raised inside a handler (a failed `assert`, say) is re-raised with its
original stacktrace when the expectations are verified.

```elixir
test "the client retries once" do
  bypass = Passby.open()

  Passby.expect(bypass, "GET", "/flaky", 2, fn conn ->
    Passby.Conn.resp(conn, 500, "")
  end)

  MyClient.get("#{bypass.url}/flaky")
  # Fails the test if the client did not retry exactly once.
end
```

`Passby.pass/1` opts an instance out of verification, for when the request is
issued by a process the test cannot await, or when a handler is meant to fail:

```elixir
Passby.expect(bypass, fn conn ->
  Passby.pass(bypass)
  Passby.Conn.resp(conn, 200, "")
end)
```

Verification is automatic under ExUnit, through `ExUnit.Callbacks.on_exit/2`,
which ships with Elixir, so it adds no dependency. Under any other test
framework, call `Passby.verify_expectations!/1` yourself. Passing
`verify: false` to `Passby.open/1` turns off the automatic check and leaves
`verify_expectations!/1` as the only way to run it. Use it when `Passby` is a
plain fake server rather than a test double, and when a test needs to assert a
verification failure without failing itself.

Verification waits for the handlers still running when it starts. One that has
not returned yet may still fail, and a request whose handler was killed was
never actually answered. `Passby.pass/1` releases them along with the
expectations.

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

`open/1`, `expect/2`, `expect/3`, `expect/4`, `expect/5`, `expect_once/2`,
`expect_once/4`, `stub/4`, `pass/1`, `down/1` (including waiting for in-flight
handlers), `up/1`, `verify_expectations!/1`, automatic verification on test
exit, `:param` route patterns, `conn.params` / `conn.query_params` /
`conn.path_params` / `conn.port`, and route redefinition (last definition
wins).

The following differs from `Bypass` on purpose
(`test/bypass_compat_test.exs` covers each of these):

| Bypass | Passby (current) |
| --- | --- |
| `verify_expectations!/1` raises "Not available in ExUnit, as it's configured automatically", and the `:test_framework` setting selects ExUnit or ESpec | `verify_expectations!/1` runs the check under any framework, so it can also assert mid-test, and it does not stop the instance; ExUnit is detected at `open/1` and there is no `:test_framework` setting |
| `pass/1` must be called before `down/1` inside a handler, or `down/1` waits for the handler that is calling it | A handler never waits for itself, so either order works |
| Errors carry the route only when one was declared; an unexpected request reports `{:any, :any}` | An unexpected request reports the method and path that actually arrived |

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
