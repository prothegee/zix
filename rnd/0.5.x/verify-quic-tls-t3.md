# Verify: QUIC-TLS live handshake gate (http3-plan.md phase T3)

T3 is the first live gate. Every phase up to here (Layer C, Layer Q, T1, T2) is a self-contained
deterministic check against RFC vectors or normative rules. T3 is different on purpose: the oracle
is a real curl --http3 handshake against a running zix server, the same oracle the QUIC Interop
Runner uses. It is the point where the stack stops being proven piece by piece and starts being
proven end to end.

## Status: PASS (2026-06-25)

The assembled zix HTTP/3 server exists (`src/udp/http3/` + `examples/http3_basic.zig`, port 9063):
UDP I/O (zix.Udp), packet protection (Layer C), the transport state machine (Layer Q), and the TLS
1.3 handshake driven over CRYPTO frames (T1 / T2) are wired together with the live-handshake driver.

The live handshake runs and passes:

- curl (8.20.0, ngtcp2 / nghttp3) completes the TLS 1.3 handshake over QUIC, validates the ECDSA
  P-256 certificate, gets HTTP/3 200, and exits cleanly (exit 0).
- The same round trip is also driven by a hermetic native QUIC client (no external tool) in
  `test-runner-http3` / `test-runner-all`, so the gate holds with or without curl present.

## Oracle

RFC 9001 + RFC 8446, observed through curl --http3-only. A successful run means curl negotiated the
"h3" ALPN, exchanged Initial and Handshake packets, completed the TLS 1.3 handshake carried in
CRYPTO frames, and installed 1-RTT keys. From here the QUIC Interop Runner (handshake, transfer,
retry, resumption, multiplexing, keyupdate, http3) becomes the broader oracle.

## Run

```sh
bash rnd/0.5.x/verify-quic-tls-t3.sh
```

Point the gate at the built example:

```sh
ZIX_HTTP3_SERVER=zig-out/bin/example-http3_basic bash rnd/0.5.x/verify-quic-tls-t3.sh
```

The hermetic, tool-free equivalent is `zig build test-runner-http3` (the native client), folded into
`test-runner-all`.

## Expect

- Step 1 prints `PASS` for curl HTTP/3 capability.
- Step 2 locates the server via `ZIX_HTTP3_SERVER` or a built example binary.
- Step 3 launches it, runs `curl --http3-only`, and prints `PASS` on the completed handshake (HTTP/3
  200, clean exit).
