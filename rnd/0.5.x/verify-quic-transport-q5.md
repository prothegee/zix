# Verify: QUIC close + reset + anti-amplification (http3-plan.md phase Q5)

Q5 closes Layer Q with how a connection ends and how it is protected from abuse before the peer
address is validated. Four rules: CONNECTION_CLOSE field layout, the closing / draining states, the
stateless reset, and the server-side anti-amplification limit plus the Initial datagram floor.

## Oracle

RFC 9000 section 19.19 + section 10.2 + section 10.3 + section 8.1:

- Section 19.19 fixes the CONNECTION_CLOSE field layout. The QUIC variant (0x1c) carries a Frame
  Type field, the application variant (0x1d) does not. The PoC parses both and confirms the field
  presence difference and the error code / reason.
- Section 10.2 fixes the termination states: an endpoint that sends CONNECTION_CLOSE enters closing,
  one that receives it enters draining, and both end in closed on timeout. The draining state sends
  no packets.
- Section 10.3 fixes stateless reset detection by the trailing 16 bytes of a datagram, with a 21
  byte minimum for a valid short-header packet, and the rule that a reset MUST NOT be three times or
  more larger than the packet it answers.
- Section 8.1 fixes the anti-amplification limit: before address validation a server MUST NOT send
  more than three times the bytes it received, and a client Initial datagram MUST be at least 1200
  bytes.

Crafted frames, byte counts, and datagrams are exercised in process, the same as the other Q
phases. From phase T (handshake) onward the oracle becomes curl --http3 and the QUIC Interop Runner.

## Run

```sh
bash rnd/0.5.x/verify-quic-transport-q5.sh
```

## Expect

The PoC checks 25 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 19.19 CONNECTION_CLOSE | 0x1c with frame type + reason, 0x1d without frame type |
| 10.2 closing / draining | state transitions, draining sends nothing, closing may send |
| 10.3 stateless reset | trailing-token detect, mismatch, too-small, 3x size cap |
| 8.1 anti-amplification | 3x send cap before validation, lifted after, 1200-byte Initial floor |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
