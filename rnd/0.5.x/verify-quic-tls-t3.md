# Verify: QUIC-TLS live handshake gate (http3-plan.md phase T3)

T3 is the first live gate. Every phase up to here (Layer C, Layer Q, T1, T2) is a self-contained
deterministic check against RFC vectors or normative rules. T3 is different on purpose: the oracle
is a real curl --http3 handshake against a running zix server, the same oracle the QUIC Interop
Runner uses. It is the point where the stack stops being proven piece by piece and starts being
proven end to end.

## Status: capability ready, live handshake pending Layer I

The live handshake requires an assembled zix HTTP/3 server: UDP I/O (zix.Udp), packet protection
(Layer C), the transport state machine (Layer Q), and the TLS 1.3 handshake driven over CRYPTO
frames (T1 / T2), all wired together. That assembly is the integration milestone (Layer I, `src/udp/
http3/` + an example), which does not exist yet.

So this gate does two honest things and no more:

- Confirms the oracle tool is present: this machine's curl (8.20.0, ngtcp2 / nghttp3) reports HTTP3
  support, so the gate can run the moment a server exists.
- Reports the handshake itself as PENDING. It does not fabricate a pass. T1 and T2 prove the QUIC-TLS
  join deterministically, but a completed live handshake is only claimed once it actually runs.

## Oracle

RFC 9001 + RFC 8446, observed through curl --http3-only. A successful run means curl negotiated the
"h3" ALPN, exchanged Initial and Handshake packets, completed the TLS 1.3 handshake carried in
CRYPTO frames, and installed 1-RTT keys. From here the QUIC Interop Runner (handshake, transfer,
retry, resumption, multiplexing, keyupdate, http3) becomes the broader oracle.

## Run

```sh
bash rnd/0.5.x/verify-quic-tls-t3.sh
```

Once the Layer I server is built, point the gate at it:

```sh
ZIX_HTTP3_SERVER=zig-out/bin/tls_http3_basic bash rnd/0.5.x/verify-quic-tls-t3.sh
```

## Expect

- Step 1 prints `PASS` for curl HTTP/3 capability.
- Step 2 locates the server via `ZIX_HTTP3_SERVER` or a built example binary.
- With no server: prints `PENDING` and exits 0 (capability confirmed, handshake not run, not faked).
- With a server: step 3 launches it, runs `curl --http3-only`, and prints `PASS` on a completed
  handshake or `FAIL` otherwise.
