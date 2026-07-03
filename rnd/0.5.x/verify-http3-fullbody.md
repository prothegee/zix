# Verify: HTTP/3 full-body delivery under concurrency

Tool: `curl` built with HTTP/3 (ngtcp2), driving `rnd/0.5.x/h3-fullbody-gate.sh`.

## Why this exists

req/s alone cannot tell a real result from a broken one. A send-path change that truncates a large
multi-packet response but still sends a FIN with a 2xx status makes the client (h2load or curl) count
the response as complete. Throughput then looks excellent while the bytes actually delivered collapse.
This was hit once: a static-h3 run reported a false 186,902 r/s while serving ~305 bytes per response
against 63 KiB fixtures (the free-on-ack send-stream retirement leaked slots under concurrency). The
gate is the check that would have caught it before the bench.

## The signal

The one number that separates a real result from truncation:

    data-bytes / done  ~=  expected body size

If req/s rises but that ratio drops, it is truncation, not throughput.

## How to run

Against the HttpArena container (real fixtures, closest to the bench):

```
podman run -d --rm -p 8443:8443/tcp -p 8443:8443/udp \
  -v <arena>/data:/data:ro --name h3gate localhost/httparena-zix_uring_http3-ed25519:latest
rnd/0.5.x/h3-fullbody-gate.sh 64 200 307200 8443 /static/vendor.js   # vendor.js is 307200 bytes
podman rm -f h3gate
```

Against the http3 example (it ships a permanent `/big` route serving a 256 KiB body for exactly this):

```
zig build example-http3                                  # build; binary in zig-out/bin/example-http3_basic
zig-out/bin/example-http3_basic &                        # binds 127.0.0.1:9063
rnd/0.5.x/h3-fullbody-gate.sh 64 200 262144 9063 /big
```

Sweep the concurrency (1, 8, 32, 64) to find where full-body delivery first breaks. All-full at every
concurrency is the pass; the concurrency where sizes start dropping is where loss recovery is missing.

## Result on record (2026-07-01)

- ring 64 + on-send stream retirement (no free-on-ack): PASS at c1 / c8 / c32 / c64, and at 200
  requests over c64 (all full 262144). Every in-flight packet stays in the 64-entry sent-range ring, so
  a lossless loopback path delivers the whole body under concurrency.
- Gate self-test (a deliberate FIN at 5000 bytes): FAIL as expected (full=0), confirming the gate
  detects truncation rather than only ever passing.

## Limit

`curl --parallel` multiplexes streams across a small number of connections, not necessarily 64 streams
on one connection the way `h2load -m 64` does. So this is a fast local pre-check, not a replacement for
the isolate bench: the authoritative full-body confirmation is still the harness reporting
`data / done ~= 63 KiB` on static-h3.
