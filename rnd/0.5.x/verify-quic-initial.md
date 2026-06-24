# Verify: QUIC Initial packet protection (http3-plan.md phase C1)

The HTTP/3 stack rests on QUIC packet protection (RFC 9001). Phase C1 derives the Initial keys and
seals the client Initial packet. This is the deterministic crypto bottom of the stack, so it is
checked the same way the TLS 1.3 key schedule is: against a published worked example, not a live
peer.

## Oracle

RFC 9001 Appendix A. The RFC publishes a full worked example for QUIC version 1:

- Appendix A.1: the Initial secret, the client and server Initial secrets, and the per-direction
  `quic key` / `quic iv` / `quic hp` material, all derived from the client Destination Connection ID
  `8394c8f03e515708`.
- Appendix A.2: the unprotected client Initial header and payload, the header-protection sample and
  mask, and the byte-exact protected packet.

No external tool is used at this layer. A live QUIC client (curl --http3, ngtcp2) picks random
connection IDs, so it cannot reproduce these exact bytes. The published vectors are the canonical
oracle, the same role RFC 8448 plays for the TLS 1.3 key schedule. From phase T (handshake) onward
the oracle becomes curl --http3 and the QUIC Interop Runner.

## Run

```sh
bash rnd/0.5.x/verify-quic-initial.sh
```

## Expect

The PoC checks 15 vectors and prints `ok` for each:

| Group | Vectors |
| :- | :- |
| A.1 secrets | initial_secret, client_initial_secret, server_initial_secret |
| A.1 keys | client key / iv / hp, server key / iv / hp |
| A.2 protection | sample, mask[0..5], protected header, protected packet head, protected packet tag |

The matching GCM tag confirms the whole 1162-byte payload is byte-exact, since the tag authenticates
the entire payload and header. On success the script prints `PASS` and exits 0. Any divergence prints
`FAIL` with the expected and actual bytes and exits non-zero.
