# Verify: QUIC ChaCha20-Poly1305 short header + key update (http3-plan.md phase C3)

QUIC mandates two AEADs. C1 proved AES-128-GCM on a long-header (Initial) packet. Phase C3 proves
the other one, AEAD_CHACHA20_POLY1305, on a short-header (1-RTT) packet, plus the key-update secret
derivation. ChaCha20-Poly1305 changes two things over the AES variant: the AEAD itself, and the
header-protection mask (RFC 9001 5.4.4 runs ChaCha20 over the sample instead of AES-ECB).

## Oracle

RFC 9001 section 5.4.4 + 6.1 + Appendix A.5. The RFC fixes the version-1 values:

- A.5 publishes an application write secret and the four values a server derives from it via
  HKDF-Expand-Label: key (`quic key`), iv (`quic iv`), hp (`quic hp`), and ku (`quic ku`). The ku
  value is the next-generation secret a key update rolls to (6.1), so the derivation is checked.
- A.5 then publishes a minimal short-header packet (empty Destination Connection ID, a single PING
  frame, packet number 654360564 on 3 bytes). The nonce, payload ciphertext, header sample, mask,
  protected header, and full packet must all match byte-exact.

Retaining the old keys and tracking two receive-key sets across a phase flip is connection state,
not a cryptographic vector, so it belongs to the engine (Layer Q), not this PoC.

No external tool is used at this layer, the same as C1 / C2: the connection IDs are peer-chosen, so
a live peer cannot reproduce these exact bytes. From phase T (handshake) onward the oracle becomes
curl --http3 and the QUIC Interop Runner.

## Run

```sh
bash rnd/0.5.x/verify-quic-keyupdate.sh
```

## Expect

The PoC checks 10 vectors and prints `ok` for each:

| Group | Vectors |
| :- | :- |
| A.5 derivation | key, iv, hp, key-update secret (quic ku) |
| A.5 protection | nonce, payload ciphertext, sample, mask, protected header, protected packet |

The ChaCha20-based mask is the first 5 bytes of ChaCha20 run over zero bytes, keyed by hp, with the
sample split into a 4-byte counter and a 12-byte nonce. On success the script prints `PASS` and
exits 0. Any divergence prints `FAIL` with the expected and actual bytes and exits non-zero.
