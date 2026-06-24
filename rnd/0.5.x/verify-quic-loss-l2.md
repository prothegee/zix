# Verify: QUIC PTO + congestion control (http3-plan.md phase L2)

L1 estimated the RTT and declared loss. L2 is the rest of the recovery brain: the Probe Timeout that
fires when no acknowledgement arrives, and the NewReno congestion window that paces how much may be
in flight.

## Oracle

RFC 9002 section 6.2 + section 7:

- 6.2.1 fixes PTO = smoothed_rtt + max(4 * rttvar, kGranularity) + max_ack_delay, where the Initial
  and Handshake spaces use max_ack_delay 0, and each consecutive timeout doubles the period.
- 7.2 fixes the initial congestion window min(10 * mds, max(2 * mds, 14720)) and the minimum window
  2 * mds. 7.3 fixes the NewReno states: slow start adds the acked bytes while below ssthresh,
  congestion avoidance adds one datagram per window of acked bytes. 7.3.2 / 7.6 fix the loss
  reduction factor (the window halves into ssthresh, clamped to the minimum) and persistent
  congestion (collapse to the minimum window). kPersistentCongestionThreshold is 3 and kInitialRtt is
  333 ms.

Integer bytes and microseconds make every value exact. No external tool is used; this is sender-side
pacing logic.

## Run

```sh
bash rnd/0.5.x/verify-quic-loss-l2.sh
```

## Expect

The PoC checks 20 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 6.2.1 PTO | formula, Initial-space max_ack_delay 0, granularity floor, doubling backoff |
| 7.2 window bounds | initial window (two datagram sizes), minimum 2*mds |
| 7.3 NewReno | slow start, congestion event halving, congestion avoidance, persistent congestion |
| 7 constants | kPersistentCongestionThreshold 3, kInitialRtt 333 ms, loss reduction 1/2 |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` with want / got and exits
non-zero.
