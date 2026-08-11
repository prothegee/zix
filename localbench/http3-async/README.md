# localbench: http3-async

zix.Http3 on the `.ASYNC` dispatch model: a single worker on UDP 8443. Pure-Zig QUIC on
`std.crypto` (RFC 9000, 9001, 9002, 9114), NewReno with PTO retransmit and
rolling MAX_STREAMS / MAX_DATA credit.

QUIC on UDP 8443. TLS 1.3 rides inside the handshake and ALPN h3 is negotiated
by the engine. There is no cleartext mode, so a missing certificate is fatal
here rather than something to degrade past.

<br>

## What is cached, and what is not

| Route | Per request |
| :- | :- |
| `/baseline2` | the sum computed from the query |
| `/static/*` | engine `public_dir`, 30 s window, see below |

No response cache and nothing pre-serialized at startup.

**The static window is mandatory on this engine.** An HTTP/3 response body
outlives the handler call: a body too large for one packet is parked in a
send-stream slot and read again for every packet, and again for every
retransmission, until the client acknowledges all of it. So the body cannot be
handler memory. It comes from the static cache as mapped bytes with the pin
held past the handler, which means `public_dir_cache_ttl_ms` above zero is
what makes static serving work at all. At zero the router serves no file and
falls through to 404.

That is a protocol constraint, not a caching choice, and it is the one place
localbench holds something past a request on purpose.

<br>

## Profiles

| Profile | Drives |
| :- | :- |
| `baseline-h3` | `/baseline2?a=..&b=..` over QUIC |
| `static-h3` | 20-file mix, br and gzip negotiated |

<br>

## What this entry does not do

`/baseline2` sums the query only, where the h1 and h2 baselines also add a
POST body. The HTTP/3 dispatch path builds its Request from the method, path,
and accept-encoding, and never fills `body`, so a request body cannot reach a
handler on this engine yet. `baseline-h3` drives GET, so the profile is
covered either way.

<br>

## Layout

```
http3-async
|
|___/src
|   |___/handlers
|   |   |___baseline.zig               (the /baseline2 route)
|   |
|   |___/shared
|   |   |___paths.zig                  (fixture and certificate paths)
|   |
|   |___main.zig                       (route table + server config)
|
|___build.zig
|___build.zig.zon
|___meta.json
|___README.md
```

<br>

## Run it

```bash
./scripts/localbench-build.sh http3-async
./scripts/localbench-validate.sh http3-async
./scripts/localbench-run.sh http3-async
```

Validation drives QUIC directly with `curl --http3-only`, which refuses to
fall back to TCP, so a pass is HTTP/3 and nothing else.
