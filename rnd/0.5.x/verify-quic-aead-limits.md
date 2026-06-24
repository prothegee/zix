# Verify: QUIC AEAD usage limits + constant-time tamper rejection (http3-plan.md phase C4)

C1 to C3 proved the QUIC crypto is byte-exact. Phase C4 closes Layer C with the two safety rules
that bound how long one key may be used, so overuse cannot hand an attacker an advantage. This is a
different kind of proof from C1 to C3: there is no Appendix-A worked packet here, the oracle is the
RFC's normative limit constants plus std.crypto's constant-time authenticated decrypt.

## Oracle

RFC 9001 section 6.6 (Limits on AEAD Usage) and 9.5 (Header Protection Timing Side Channels):

- 6.6 confidentiality: an endpoint MUST initiate a key update before sending more packets under one
  key than the AEAD's confidentiality limit permits. AES-128-GCM and AES-256-GCM are 2^23 packets,
  ChaCha20-Poly1305 exceeds the 2^62 packet-number space so it is disregarded.
- 6.6 integrity: an endpoint MUST count received packets that fail authentication and, on reaching
  the integrity limit, close the connection with AEAD_LIMIT_REACHED. AES-128-GCM and AES-256-GCM
  are 2^52 forged packets, ChaCha20-Poly1305 is 2^36. AES-128-CCM (2^21.5) is not offered by zix.
- 9.5: removing header protection, recovering the packet number, and removing packet protection
  MUST happen together with no timing side channel. A flipped bit anywhere under the authentication
  MUST be rejected, and the rejection feeds the integrity counter rather than short-circuiting.
  std.crypto's AEAD decrypt does the tag check in constant time, and std.crypto.timing_safe.eql is
  the constant-time primitive for any manual token compare (stateless reset, retry tag).

## Run

```sh
bash rnd/0.5.x/verify-quic-aead-limits.sh
```

## Expect

The PoC checks 20 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 6.6 confidentiality limits | aes-128-gcm 2^23, aes-256-gcm 2^23, chacha20 disregarded |
| 6.6 integrity limits | aes-128-gcm 2^52, aes-256-gcm 2^52, chacha20 2^36 |
| 6.6 send accounting | below limit ok, at limit key-update, no-key-update close, chacha20 never trips |
| 6.6 receive accounting | below limit ok, at limit close (AEAD_LIMIT_REACHED) |
| 9.5 constant-time | valid decrypts, flipped tag / ciphertext / header rejected, failure counts, timing_safe.eql both ways |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` with the offending check
and exits non-zero.
