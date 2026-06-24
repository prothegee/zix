# Verify: QUIC-TLS version + key discard + 0-RTT (http3-plan.md phase T2)

T1 joined the handshake to TLS. T2 adds the three guard rules that keep the join safe: QUIC is TLS
1.3 only, Initial keys are discarded aggressively once the handshake advances, and rejected 0-RTT
packets are never processed.

## Oracle

RFC 9001 section 4.2 + 4.9.1 + 4.6.2:

- Section 4.2 fixes the TLS version floor. QUIC uses TLS 1.3 or newer, and an endpoint MUST
  terminate the connection if a version below 1.3 is negotiated. The PoC accepts 0x0304 and a newer
  0x0305, and rejects 0x0303 (1.2) and 0x0302 (1.1).
- Section 4.9.1 fixes the Initial-key discard. The trigger is role-split: a server discards on first
  successfully processing a Handshake packet, a client on first sending one. After discard an
  endpoint MUST NOT send Initial packets. The PoC confirms each role discards on its own trigger and
  not the other's.
- Section 4.6.2 fixes 0-RTT acceptance and rejection. A server signals acceptance with an early_data
  extension in EncryptedExtensions, and a rejecting server MUST NOT process any 0-RTT packets. zix
  rejects 0-RTT by default because session resumption is deferred.

No external tool is used at this layer: these are policy and state machines exercised in process. T3
is where the live curl --http3 oracle begins.

## Run

```sh
bash rnd/0.5.x/verify-quic-tls-t2.sh
```

## Expect

The PoC checks 15 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 4.2 TLS version | 1.3 + newer accepted, 1.2 + 1.1 terminate |
| 4.9.1 Initial key discard | server on process, client on send, wrong-trigger no-op, no Initial after |
| 4.6.2 0-RTT | reject omits early_data + no process, accept signals + processes, zix default reject |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
