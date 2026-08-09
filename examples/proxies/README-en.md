# zixer proxy demos

> Bahasa Indonesia: [`README-id.md`](README-id.md)

Runnable demos for `zixer`, the proxy gateway built on the zix engines. Each demo is one
upstream server (`*.zig` here) plus one site config (`sites/*.cfg`). The site config is the
whole configuration: no code in the upstream knows it is being proxied.

This directory is a zixer root dir, so `--dir examples/proxies` points zixer at it.

For the key by key reference behind these files, read [`docs/zixer/config-en.md`](../../docs/zixer/config-en.md).

<br>

## Setup

Run everything from the repository root. Paths in the site configs (`public_dir`,
`tls_cert`) are relative to where the daemon runs.

```bash
zig build zixer                 # builds zig-out/bin/zixer-<arch>-<os>-<optimize>
zig build zixer-examples        # builds every demo upstream
mkdir -p examples/proxies/logs  # logs/ is not in the repository, create it once
```

Shorten the paths for the rest of this page. The triplet is this machine's, swap in yours, and
`MODE` is the lowercased `-Doptimize` value, which is `debug` when the flag is not passed:

```bash
BIN=./zig-out/bin
TRIPLET=x86_64-linux
MODE=debug
ZIXER=$BIN/zixer-$TRIPLET-$MODE
```

Check the configs before starting anything. Every file gets a verdict and every problem
gets a fix hint:

```bash
$ZIXER --dir examples/proxies status
$ZIXER --dir examples/proxies list
```

<br>

## Daily flow

```bash
$BIN/zixer-example-http1-$TRIPLET-$MODE &   # the upstream first
$ZIXER --dir examples/proxies start http1.cfg   # spawns the daemon if needed
curl http://127.0.0.1:9100/
$ZIXER --dir examples/proxies stop http1.cfg
$ZIXER --dir examples/proxies daemon stop       # stops every site and exits
```

`restart <site.cfg>` re-reads the file from disk, which is what a certbot deploy hook
calls after a renewal.

<br>

## The matrix

| Demo | Edge | Upstream | Proves |
| :- | :- | :- | :- |
| http1 | 9100 | 9101 | plain request proxy, keep-alive on both legs |
| http1_sse | 9102 | 9103 | streamed response passthrough, no idle timeout |
| http1_ws | 9104 | 9105 | rfc 6455 upgrade tunnel, pick pinned at upgrade |
| http2 | 9106 | 9107 | h2 client edge, http1 re-originated to the upstream |
| grpc | 9108 | 9109 | h2 end to end, trailers survive |
| http3 | 9110 | 9111 | QUIC client edge, http1 upstream |
| udp | 9112 | 9113 | per-flow datagram forward |
| static | 9114 | none | static-only site, spa_fallback, its own cache window |
| mixed | 9115 | 9116 | public_prefix static beside a proxied backend |
| round_robin | 9117 | 9118, 9119 | rotation, and bounded retry when one dies |
| tls | 9120 | 9121 | TLS terminated at zixer, cleartext upstream |
| rtc_signal | 9122 | 9105 | webrtc signaling: wss edge over a websocket backend |
| rtc_media | 9123 | 9083 | a whole webrtc session across the per-flow forward |
| bounds | 9124 | 9125 | client budget, 408 on a partial head, 503 past the connection limit |
| headers | 9128 | 9129 | the two cfg header sections, tokens, and the replace rule |

Every site config carries its own run and drive commands in its header, so
`sites/<demo>.cfg` is the reference for that demo.

<br>

## Which config key each demo shows

| key | demo to read |
| :- | :- |
| `engine` | one per engine: http1, http2, grpc, http3, udp |
| `ip`, `port` | every demo |
| `tls`, `tls_cert`, `tls_key` | tls, http3, rtc_signal |
| `upstreams` (one) | http1 |
| `upstreams` (several) | round_robin |
| `public_dir`, `spa_fallback` | static |
| `public_prefix` | mixed |
| `public_dir_cache_ttl_ms` | main.cfg for the daemon default, static for a site override |
| `public_dir_cache_max_entries` | main.cfg, there is one cache table per daemon |
| `kernel_backlog` | main.cfg, inherited by every site here |
| `client_timeout_ms`, `client_conn_limit` | bounds |
| `upstream_connect_timeout_ms`, `upstream_idle_ttl_ms` | bounds |
| `[response_headers]`, `[request_headers]` | headers |

`acme_webroot`, `acme_proxy`, `upstream_timeout_ms`, `force_https`, and `redirect_host` have
no demo: a real challenge needs port 80 and a certificate authority, a read deadline only
shows itself against a backend that stalls on purpose, and the redirect needs the same
privileged port 80 the challenge does. Their behavior is described in
[`docs/zixer/config-en.md`](../../docs/zixer/config-en.md).

The bounds demo sets `upstream_connect_timeout_ms` on a backend that is really there, so the
key is visible in the file without slowing the demo down. It only shortens a wait against an
address that answers nothing at all.

<br>

## Running the whole matrix

Every demo above is also a runner check. The runner starts each upstream, asks the daemon
to bind that demo's site, drives a native client through the edge, and reports one line
per demo:

```bash
zig build zixer-test-runner-all
zig build zixer-test-runner-all -- --only http3   # one demo
```

It builds its own throwaway root under `tmp/`, copied from this directory, so it never
touches a daemon already running on `examples/proxies`.

<br>

## Notes

- Ports 9100 to 9129 belong to these demos, apart from 9126 and 9127, which the runner binds
  on its own side for the two udp rows. The upstreams the rtc pair reuses are the websocket
  demo (9105) and `examples/webrtc/webrtc_datachannel_echo.zig` (9083).
- The bounds demo cuts a client after two seconds, so a connection held open by hand is
  expected to be taken away. That is the demo working, not the daemon misbehaving.
- The TLS and http3 demos use `examples/certs/ecdsa_p256_cert.pem`, self-signed for
  `localhost` and `127.0.0.1`, so clients need `-k`. Reach them as `https://localhost:<port>`:
  a Host that matches no name in the certificate is answered 421 by the edge.
- The http3 demo needs a curl built with HTTP/3 (`curl --version` lists `HTTP3`).
- The websocket demos need `websocat` or `wscat`, the grpc demo needs `grpcurl`.
- One daemon serves every started site, so several demos can run at once. Each site owns
  its port, and a collision is refused at `start` rather than silently ignored.
