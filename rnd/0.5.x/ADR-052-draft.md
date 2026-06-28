# ADR-052 draft: multiplexed TLS dispatch for Http2 and gRPC

Lean note. The full record lives in `docs/adr-en.md` / `docs/adr-id.md` (ADR-052).

## Decision in one line

For `.EPOLL` / `.URING`, terminate TLS in place on a per-core multiplexed epoll loop (one `SO_REUSEPORT` listener + epoll per worker, resumable TLS 1.3 session per connection), instead of the ADR-046 socketpair plus thread-per-connection terminator.

## Why

Thread-per-connection TLS thrashes at 512c / 1024c (one OS thread per connection, scheduler churn). The cleartext EPOLL / URING engines already multiplex many connections per core. The TLS path now matches that shape.

## Shape

| Path | Dispatch | File |
| :- | :- | :- |
| multiplexed, per-core | `.EPOLL` / `.URING` | `src/tcp/http2/tls_mux.zig`, `src/tcp/http2/grpc/tls_mux.zig` |
| resumable session (linchpin) | shared | `src/tcp/tls/tls_session.zig` |
| inline-mux, thread-per-conn (also TLS 1.2) | `.ASYNC` / `.POOL` / `.MIXED` | `src/tcp/tls/h2_terminator.zig` via `tls_serve.zig` |

## Local gate (6 cores, worst case vs the 64-core box)

- Http2 RSA 512c (ReleaseFast): no hang, one worker thread per core.
- gRPC 512c and 1024c: 200000/200000 ok, 0 failed, one worker thread per core, no hang.
- Old thread-per-conn at 512c: load average in the hundreds, minutes to finish.

## Open

- Multiplexed path is TLS 1.3 only. The 1.2 fallback stays on the thread-per-conn path.
- `.URING` + TLS routes to the same epoll loop. A native io_uring TLS loop is later.
- Http1 TLS is still thread-per-conn (json-tls rides it). Porting the same dispatch to Http1 is the remaining step.
