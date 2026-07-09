# Verify: TLS dual listener (tls_port, ADR-060)

External checks with public tools (curl, openssl s_client, websocat) against the dual-listener
example. The in-repo coverage lives in `tests/integration/*/tls_dual_test.zig` (EPOLL, URING, POOL
per engine) plus the `tls-http1-dual` step in `test-runner-all`, this doc is the out-of-band pass.

## Serve

```sh
zig build example-tls_http1_dual
./zig-out/bin/tls_http1_dual
```

One process, two listeners: cleartext on 9076, TLS on 9077, same worker fleet.

## Checks

1. Same route on both transports:

```sh
curl -s http://localhost:9076/
curl -sk https://localhost:9077/
```

Expect the same body (`hello from the dual listener`) from both.

2. Handshake policy on the TLS side (TLS 1.3, cert served):

```sh
openssl s_client -connect localhost:9077 -tls1_3 -brief </dev/null
```

Expect `Protocol version: TLSv1.3` and a completed handshake.

3. The cleartext port never answers TLS (sanity that the ports are distinct stacks):

```sh
openssl s_client -connect localhost:9076 -tls1_3 -brief </dev/null
```

Expect a handshake failure.

4. Keep-alive over the TLS side (one connection, two requests):

```sh
curl -sk https://localhost:9077/ https://localhost:9077/ -v 2>&1 | grep -c "Re-using existing connection"
```

Expect `1`.

5. Memory shape (the point of the feature): with the server under both-port load, one worker fleet
   should show in `/proc/<pid>/status` (Threads count equals workers + main, not doubled). Compare
   against the old two-launch setup if a before / after is wanted.

## WebSocket and SSE over the dual TLS side (Http1 mux loop)

Served by the same loop since ADR-060. Spot-check with websocat against a WS route (swap the
example handler for `examples/tls/tls_http1_ws.zig`'s and rebuild, or use an HttpArena-style entry):

```sh
websocat --insecure wss://localhost:9077/ws
```

Expect echo. SSE: a `beginStream()` route streams one TLS record per write:

```sh
curl -skN https://localhost:9077/events
```

## Result

- date: (fill on run)
- zig version: (fill on run)
- checks 1-4: (PASS / FAIL each)
