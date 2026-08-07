# zixer low-level design

This document covers the internals: the config grammar, the control wire, the registry rules, what each edge does on the wire, and the fixed limits. For the shape of the gateway read `hld-en.md` first. For key by key config guidance read `config-en.md`.

<br>

## Config scanning

One scanner reads both `main.cfg` and every site file. It allocates nothing: every key and value is a slice into the file content, which the caller keeps alive.

Per line:

1. Cut at the first `#`, so a trailing comment disappears and a comment-only line becomes empty.
2. Trim spaces, tabs, and `\r`, so CRLF files read the same as LF files.
3. Skip empty lines.
4. Split at the first `:` only. The value keeps any further colons, which is what makes `C:/certs/full.pem` and `::1:9000` work.
5. Trim both sides. An empty key or an empty value is a fault, not a skip.

A comma list value is iterated with the same no-allocation rule, and an empty item (`a,,b`, or a trailing comma) comes back as an empty string so the schema can fault it rather than quietly dropping a typo.

Booleans accept `true` and `false` only. `True`, `yes`, and `1` all fault, because a config that guesses is a config that surprises.

## Numeric values

Any numeric key runs through the expression evaluator: integers, `+ - * /`, and parentheses, with multiply and divide binding first, left to right, capped at 32 levels of nesting.

| rule | reason |
| :- | :- |
| division must be exact | `10 / 4` is a typo far more often than an intent, and silent truncation hides it |
| division by zero faults | same |
| overflow faults | the result must fit 64-bit math before it is cast to the field type |
| the whole value must be consumed | `1024 junk` faults rather than reading `1024` |

Each error maps to one hint: `not a number or integer math (i.e. 16 * 1024)`, `division by zero`, `division leaves a remainder, config values must be exact`, `number does not fit 64-bit integer math`.

## Faults

Validation never stops at the first problem. Every schema check appends to a fault list of `{ key, hint }` pairs, and the caller decides what to do with a non-empty list:

| caller | behavior |
| :- | :- |
| `zixer status` | prints every fault under the file's block, exits 1 |
| the daemon, on main.cfg | refuses to start, points at `zixer status` |
| the daemon, on a site | refuses that `start`, points at `zixer status <name>` |

A bad field keeps its default instead of poisoning the rest of the parse, so one report shows every problem in the file at once.

<br>

## Root dir resolution

```mermaid
flowchart TB
    arg{--dir given?} -->|yes| use1[use it, source ARG]
    arg -->|no| env{ZIXER_DIR set and not empty?}
    env -->|yes| use2[use it, source ENV]
    env -->|no| home{HOME set?}
    home -->|yes| use3[HOME/.zixer, source HOME]
    home -->|no| err[error: no root dir]
```

`USERPROFILE` stands in for `HOME` on Windows. The source is kept beside the path so `zixer` with no command can report where it would work.

<br>

## main.cfg parse

Keys are matched by name against an enum, so an unknown key is a typo report rather than a silent extra. A duplicate key faults and the first value stands.

| key | check |
| :- | :- |
| workers | fits `usize`, at most the machine thread count from `std.Thread.getCpuCount` |
| dispatch | one of `async`, `epoll`, `uring`, and off Linux only `async` |
| logs_dir, sites_dir | taken as written, defaulted to `<root>/logs` and `<root>/sites` when absent |
| kernel_backlog | fits `u31`, at least 1 |
| max_recv_buf | at least 1 |

`zixer status` adds an existence check on both directories after the parse.

## Site cfg parse

The same scan, then a cross-field pass over the whole file. The pass runs in a fixed order so the report reads the same way every time: missing required keys, TLS pairing, backend presence, static plane rules, acme pairing, then the per-engine rules. The full rule list with its exact fault text is in `config-en.md`.

`upstreams` splits into `{ host, port }` entries. The split is on the last colon, the port must parse as a non-zero `u16`, and each bad item faults on its own so a list of five names produces five hints. The host string itself is not checked here, which is why a name passes the config gate and fails later at connect time.

<br>

## Control plane

The daemon owns `<root>/control.sock`. A relative root is made absolute first, because Windows AF_UNIX rejects a relative bind path, and both sides derive the same string from the same working directory.

| property | value |
| :- | :- |
| transport | unix stream socket, one exchange per connection |
| request | one line, `verb [name]`, newline terminated |
| reply | one line, `ok: ...` or `error: ...` |
| max line | 512 bytes |
| max site name | 128 bytes |
| path limit | the platform unix socket limit, 108 bytes on Linux |

Verbs are `start`, `stop`, `restart`, `ping`, and `shutdown`. The three site verbs require a name, `ping` and `shutdown` refuse one, and anything else is answered with the usage line.

A site name on the wire must be a bare file name ending `.cfg`, with no `/`, no `\`, and no `..`. That rule is what keeps a control request from reaching outside `sites_dir`.

```mermaid
sequenceDiagram
    participant C as client
    participant D as daemon
    C->>D: connect control.sock
    C->>D: start api.cfg\n
    D->>D: read, validate, bind
    D-->>C: ok: api.cfg started on 0.0.0.0:8080\n
    C->>D: close
```

When the socket is silent, `start` and `restart` spawn the daemon from the same executable path the command ran from, wait for it to answer a `ping`, and then send the real request. A daemon that never answers is reported rather than retried forever.

<br>

## Registry rules

The daemon keeps one array of started sites. Every mutation is serial, so no lock is needed.

| rule | why |
| :- | :- |
| `start` on an already started site is refused | a silent rebind would hide a config edit that was never applied |
| `restart` on a stopped site starts it | a renewal hook must not fail because a site happened to be down |
| a port already owned by another started site is refused | tcp sites bind with address reuse, so the kernel would share the port instead of reporting the collision |
| a port a listener outside this daemon answers on is refused | the registry only sees sites in this process, a connect probe is what finds an owner in another one |
| the acme companion port counts as owned | the same collision applies to port 80, from the registry and from the probe alike |
| the listen backlog is the site value, else the main.cfg value | one default, per site override |

A config file larger than 256 KiB is refused rather than loaded.

<br>

## Site runtime

One started site owns one listener, and one of these shapes:

| engine and config | what is held |
| :- | :- |
| http1, http2, or grpc with `upstreams` or `public_dir` | a serving proxy edge over a tcp listener |
| http1, http2, or grpc with neither | the bare tcp listener, so the port is owned and a collision is visible |
| http3 with `upstreams` or `public_dir` | the QUIC edge over a bound datagram socket |
| udp with `upstreams` | the per-flow forward over a bound datagram socket |
| http3 or udp with neither | the bare datagram socket |

Tcp listeners bind with address reuse, datagram sockets bind strict.

Address reuse is why a tcp bind is preceded by a probe. Std pairs the flag with `SO_REUSEPORT` on posix, and the Windows `SO_REUSEADDR` is permissive in the same way, so a second listener joins the port rather than failing and the kernel then splits arriving connections between the two. The probe connects to the address the site is about to listen on, loopback in place of a wildcard because Windows refuses a connect to `0.0.0.0`. A live listener answers and the start is refused with `AddressInUse`, while a socket left in TIME_WAIT refuses the connect, so a restart right after live traffic still rebinds. A datagram socket needs no probe: its bind is strict and reports the collision itself.

A TLS site with acme keys, on any port other than 80, also binds port 80, and the companion port is probed the same way. That bind is not optional: if it fails, the whole `start` fails with a message naming the challenge port.

<br>

## The http1 edge

```mermaid
flowchart TB
    req[request head] --> parse[parse: request line, headers, framing]
    parse --> gate{TLS site and Host not in the certificate?}
    gate -->|yes| m421[421 misdirected request]
    gate -->|no| acme{acme path?}
    acme -->|yes| challenge[serve from webroot or relay]
    acme -->|no| static{static plane handles it?}
    static -->|yes| file[serve the file, or the spa fallback]
    static -->|no| upstream[pick, rebuild, forward]
```

Head parsing is bounded: 16 KiB of head, at most 64 headers. The body framing decision follows rfc 9112, and because the edge re-originates, `Transfer-Encoding` and `Content-Length` never cross as they arrived. The rebuilt message carries a framing header the edge chose itself.

The static plane runs before the pool when the site has one, and `public_prefix` bounds it: without a prefix the whole path space is static-first, with a prefix only that subtree is. Path resolution rejects `..` outright rather than normalizing it, rejects an embedded NUL, maps a trailing slash to `index.html`, and caps the joined path at 512 bytes. Precompressed siblings are probed in `.br` then `.gz` order against `Accept-Encoding`, with identity as the floor, and `Vary: Accept-Encoding` rides on every static response.

An exchange against the pool retries up to one attempt per upstream plus one spare, so a single stale idle connection never consumes a slot's only chance. Once a request body has started streaming, there is no retry: the body is not replayable.

A `101` from the upstream turns the connection into a raw tunnel in both directions for the rest of its life, with the upstream pick pinned for the tunnel.

## The http2 edge

Client h2 streams are served one at a time with the rest queued, and each stream is re-originated as an HTTP/1.1 request to the pool. The translation follows rfc 9113 section 8: pseudo-headers into a request line, connection-specific headers refused, the response status back into `:status`.

An extended CONNECT stream (rfc 8441) becomes a websocket bridge: DATA frames to raw bytes toward an h1 websocket upstream, and raw bytes back into DATA frames.

Prior-knowledge h2 is sniffed on a cleartext listener, so a client that never negotiates ALPN still works.

## The grpc edge

gRPC is h2 on both legs, because trailers are the status channel and re-originating to h1 would lose them. The edge opens an h2 connection to the picked upstream, allocates stream ids on it, validates and re-encodes the header block, and multiplexes frames both ways. Local answers (an unroutable request, no upstream) are produced as grpc responses, not as http errors.

## The http3 edge

The edge terminates QUIC (rfc 9000 and 9001) and HTTP/3 (rfc 9114) itself: connection state, packet number spaces, flow control, stream assembly, and QPACK (rfc 9204) field sections. Each request stream is translated into an HTTP/1.1 message for the pool, and the response is translated back. Up to 64 concurrent QUIC connections are held per site.

As on the other TLS edges, an `:authority` the certificate does not cover is answered 421.

## The udp forward

No parsing of any kind. The site socket receives a datagram, and the flow table decides where it goes.

```mermaid
flowchart LR
    client[client addr:port] --> up[up pump on the site socket]
    up --> table{known flow?}
    table -->|yes| slot[that flow's own socket]
    table -->|no| claim[claim a slot, pick the next upstream]
    claim --> slot
    slot --> backend[(upstream)]
    backend --> down[per-flow down pump] --> client
```

- A flow is one client address and port. It sticks to one upstream for its whole life, and new flows walk the upstreams round-robin.
- Each flow forwards through its own ephemeral socket, so an upstream sees one distinct peer per client. That is what ICE and DTLS state need.
- The table holds 64 flows. When all are taken, the stalest flow is marked closing and the triggering datagram is dropped, because every protocol a udp site fronts retransmits.
- A down pump only accepts datagrams from the upstream its flow picked, anything else at that ephemeral port is dropped.
- Recency is a claim counter, not a clock, so nothing here depends on time.
- Teardown is a stop flag plus a wake datagram at the site's own port, because closing a socket another thread is blocked on is not reliable across platforms.

Buffers are the full 65535 byte datagram bound in both directions, so nothing is ever truncated. This is why `max_recv_buf` changes nothing on a udp site today.

## The TLS edge

One handshake per connection over the zix TLS stack, with the ALPN preference list taken from the site engine. The negotiated protocol picks the serve path: `h2` runs the h2 edge, `http/1.1` runs the http1 edge, and no ALPN at all falls back to a preface sniff on an http2 site or plain http1 elsewhere. A close is a best-effort `close_notify` before the socket drops.

## The acme plane

Two shapes, both bound to `/.well-known/acme-challenge/`:

| key | behavior |
| :- | :- |
| `acme_webroot` | the token file is read from `<webroot>/.well-known/acme-challenge/<token>`, a miss answers `404 not found` |
| `acme_proxy` | the request is relayed to the configured backend and its reply is passed back as it came, including its own status and headers |

On a cleartext http1 site both run on the site's own listener. On a TLS site they run on the port 80 companion listener.

<br>

## Upstream pool

An O(1) round-robin over the upstreams currently up:

- `slots` holds every configured upstream, `ready` holds dense indexes of the ones up, so a pick never scans.
- Marking down is a swap-remove, marking up is an append.
- A connect failure marks the upstream down. Re-admission happens at pick time after a 3000 ms cooldown, and the sweep is gated to at most once per 200 ms so its cost never lands on every pick.
- A re-admitted upstream that is still dead is marked down again by the next failure. There is no probe thread.
- Idle keep-alive connections are cached per upstream slot, up to 4 each. Overflow is closed instead of grown.

A short spinlock guards the pool and the cache, because connection tasks run concurrently within a site.

<br>

## Fixed limits

None of these are configurable today.

| limit | value | where |
| :- | :- | :- |
| config file size | 256 KiB | main.cfg and each site file |
| control line | 512 bytes | control socket request and reply |
| site name | 128 bytes | control socket |
| control socket path | 108 bytes on Linux | the whole `<root>/control.sock` string |
| request head | 16 KiB | http1 edge |
| headers per message | 64 | http1 edge |
| static path | 512 bytes | `public_dir` plus the request path |
| idle upstream connections | 4 per upstream | per site |
| upstream cooldown | 3000 ms | per site pool |
| concurrent QUIC connections | 64 | per http3 site |
| udp flows | 64 | per udp site |
| udp datagram | 65535 bytes | per udp site |
| consecutive accept failures before a loop gives up | 100 | control loop and each site accept loop |

<br>

## Testing

Every module carries its own tests beside the code, run with `zig build zixer-unit-test`. The config surface is covered at three levels:

| level | what it proves |
| :- | :- |
| scanner and math tests | the grammar, comments, lists, and every arithmetic rule |
| schema tests | every default, every fault text, and every cross-field rule |
| daemon and runtime tests | that a parsed value reaches the bind, i.e. the backlog a site resolves |

The demo matrix under `examples/proxies` is the end-to-end layer: `zig build zixer-test-runner-all` starts each upstream, binds that demo's site in a throwaway root, drives a native client through the edge, and reports one line per demo.
