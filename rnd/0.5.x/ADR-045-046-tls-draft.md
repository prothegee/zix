# ADR-045 + ADR-046 (TLS): lean working draft

Canonical full text: `docs/adr-en.md` + `docs/adr-id.md`. This is the short note, not a copy.

## ADR-045: pure-Zig TLS, TLS 1.2 the minimum

- **Decision:** build the TLS 1.3 handshake in pure Zig (`std.crypto`), no OpenSSL / BoringSSL.
  Offer TLS 1.2 + 1.3, prefer 1.3, floor at 1.2. 1.0 / 1.1 / SSL never offered.
- **Why:** std has every primitive, so a C lib only adds build + FFI cost. 1.2 is not deprecated
  (RFC 8996 kills only 1.0 / 1.1). The version + ECDHE-AEAD-only suite policy is chosen so the
  1.2 + 1.3 posture targets the top SSL Labs grade (A+) without RSA, not a measured claim.
- **Status:** 1.3 done (RFC 8448 byte-exact). 1.2 = open required milestone. The downgrade sentinel
  becomes required once 1.2 is offered.

## ADR-046: TLS as a layer

- **Decision:** a gated blocking serve path per engine (on `tls_cert_path`), cleartext models
  untouched. Http1 = a pipe per request. Http2 = a socketpair terminator over the unchanged h2c
  engine, ALPN selects h2.
  - Superseded by ADR-052 for the Http2 / gRPC terminator: the socketpair plus second thread are gone.
    `.EPOLL` / `.URING` now multiplex TLS per core (`tls_epoll.zig` + `tls_session.zig`), and
    `.ASYNC` / `.POOL` / `.MIXED` run an inline-mux driver in `h2_terminator.zig`. Http1 still a pipe.
- **Why:** reuse the cleartext engines as-is (no perf regression), https on its own band. `zix.Tls`
  is sans-I/O, so the engine owns the socket loop.
- **Status:** Http1 https + Http2 h2 serve over TLS 1.3, green on Zig 0.16 and 0.17.
