# Verify: QUIC-TLS CRYPTO carriage + per-level keys (http3-plan.md phase T1)

Layers C and Q proved the crypto and the wire format. Layer T joins them to TLS 1.3. T1 is the join
point: in QUIC the TLS handshake does not use the TLS record layer, the handshake messages ride
directly as the payload of CRYPTO frames, reassembled by offset into one ordered stream per
encryption level, and QUIC packet protection replaces TLS record protection.

## Oracle

RFC 9001 section 4 + section 5.1:

- Section 4 fixes that TLS handshake data is carried in CRYPTO frames (RFC 9000 19.6) and
  reassembled by offset. The PoC delivers a handshake message in order, out of order (a gap holds
  back the tail until filled), and with overlap (idempotent), and confirms the reassembled bytes are
  a handshake-layer message (begin with the ClientHello type 0x01) rather than a TLS record (no 0x16
  ContentType, no 5-byte record header).
- Section 5.1 fixes the per-level key derivation: every encryption level (Initial, 0-RTT, Handshake,
  1-RTT) derives its key / iv / hp from that level's TLS secret with the same "quic" labels. The PoC
  derives the Initial level key from the DCID (the C1 vector, 16-byte AES-128-GCM) and the
  application level key from the application secret (the C3 / A.5 vector, 32-byte ChaCha20-Poly1305),
  showing one derivation across levels and AEADs.

No external tool is used at this layer: the CRYPTO reassembly is crafted in process and the key
derivation reduces to the published C1 / C3 vectors. T3 is where the live curl --http3 oracle
begins.

## Run

```sh
bash rnd/0.5.x/verify-quic-tls-t1.sh
```

## Expect

The PoC checks 11 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 4 CRYPTO reassembly | in-order, gap withholds tail, out-of-order, overlap idempotent |
| 4 no record protection | handshake-layer type, not a TLS record |
| 5.1 per-level keys | Initial from DCID, application from app secret, independence, four levels |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
