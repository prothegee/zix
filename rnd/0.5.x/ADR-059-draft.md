# ADR-059 (accepted record)

Records the response-API naming taxonomy: name every response-path function by two axes, the verb
(`send*` shapes a response, `write*` is a pure write) and an `FD` suffix when the signature takes a
raw fd. Folded into the public ADR docs (en and id) as the accepted ADR-059, kept here as the
record. A pure rename (byte-identical wire), a consistency change, not a measured one, so there is
no PoC benchmark.

## Status

Accepted. The rename landed across all five engines (Http1, WebSocket, Http2, Grpc, Http3) on Zig 0.16.

## Context

The response-writing surface grew per engine without one rule. The same idea appeared as `write*`
on one engine, `send*` on another, and raw `fdWrite*` plumbing leaked into response paths. Reading a
call did not tell you whether it shaped a response or just moved bytes, and whether it touched a raw
fd. That ambiguity kept resurfacing every time compression or a new engine was discussed.

## Decision

Name every response-path function by two independent axes:

- Verb: sends a response or any communication out gives `send*`. A pure write with no send gives
  `write*`.
- Suffix: the signature takes a raw `fd` parameter gives a trailing `FD`. An fd held inside a struct
  (used through `self`) does not count, so object methods stay clean.

| bucket | example |
| :- | :- |
| send + fd | `sendGzipFD(fd, ...)` |
| send + no fd | `Response.sendJson(...)` |
| write + fd | `writeAllFD(fd, bytes)` |
| write + no fd | `wire.writeU16(...)` |

Compression-capable engines expose the same six: `sendGzipFD`, `sendGzipCachedFD`, `sendBrotliFD`,
`sendBrotliCachedFD`, `sendNegotiateFD`, `sendNegotiateCachedFD`. Negotiate routes internally through
the same gzip / brotli path, one compression policy in one place. The precompressed / caller-encoded
primitive (`sendResponseEncodedFD` shape) stays as the layer those six build on.

## Consequences

- Wide but mechanical rename. Function bodies and parameters do not change, only names and the
  doc / comment text that references them.
- Correction lands before any new code. The two brotli twins and the uncached `sendNegotiateFD` are
  added afterward.
- HttpArena entries change call sites only, never behavior.
- Rolled out engine by engine (Http1, WebSocket, Http2, Grpc, Http3, then the full server plus shared
  tls / dispatch), gated by the full test suite on each step.
