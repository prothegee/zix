# Verify: QUIC Retry integrity tag (http3-plan.md phase C2)

A Retry packet carries a 16-byte Retry Integrity Tag (RFC 9001 5.8). It lets a client drop a
corrupted or spoofed Retry: only an entity that observed the client Initial (and so knows the
Original Destination Connection ID) can compute a valid tag. Phase C2 computes that tag and
reconstructs the Retry packet.

## Oracle

RFC 9001 section 5.8 + Appendix A.4. The RFC fixes the version-1 values:

- The Retry key `be0c690b...` and nonce `461599d3...` are themselves derived from the published
  secret `d9c9943e...` via HKDF-Expand-Label `quic key` / `quic iv`, so both are checked.
- Appendix A.4 publishes a worked Retry packet whose tag covers the Retry Pseudo-Packet (ODCID
  Length + Original Destination Connection ID `8394c8f03e515708` + the Retry packet without its
  tag). Reconstructing it must match byte-exact.

No external tool is used at this layer, the same as C1: the Original Destination Connection ID is
client-chosen, so a live peer cannot reproduce these exact bytes. From phase T (handshake) onward
the oracle becomes curl --http3 and the QUIC Interop Runner.

## Run

```sh
bash rnd/0.5.x/verify-quic-retry.sh
```

## Expect

The PoC checks 4 vectors and prints `ok` for each:

| Group | Vectors |
| :- | :- |
| 5.8 derivation | retry key, retry nonce |
| A.4 tag | retry integrity tag, full retry packet |

The tag is computed with AEAD-AES-128-GCM over an empty plaintext, so the whole 16-byte output is
the tag. On success the script prints `PASS` and exits 0. Any divergence prints `FAIL` with the
expected and actual bytes and exits non-zero.
