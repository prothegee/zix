# Verify: QUIC RTT estimation + loss detection (http3-plan.md phase L1)

Layers C / Q / T / P / H proved correctness on the wire. Layer L is the timing brain: how the sender
estimates the round-trip time and decides a packet is lost. L1 is the RTT estimator and the two loss
thresholds.

## Oracle

RFC 9002 section 5 + section 6.1:

- 5.1-5.3 fix RTT estimation. The first sample resets the estimator (smoothed_rtt = latest_rtt,
  rttvar = latest_rtt / 2, min_rtt = latest_rtt). Later samples evolve smoothed_rtt as
  7/8 * smoothed + 1/8 * adjusted and rttvar as 3/4 * rttvar + 1/4 * |smoothed - adjusted|, where the
  ack-delay adjustment subtracts the delay only if latest_rtt >= min_rtt + delay and the delay is
  capped at max_ack_delay once the handshake is confirmed. min_rtt keeps the lesser sample.
- 6.1.1 fixes kPacketThreshold = 3: a packet at least three before the largest acknowledged is lost.
  6.1.2 fixes the time threshold max(9/8 * max(smoothed_rtt, latest_rtt), kGranularity), with
  kGranularity = 1 ms. A packet older than that is lost.

Times are integer microseconds so the EWMA is exact and reproducible. No external tool is used. This
is sender-side timing logic over the RTT samples and acknowledgements Layer Q carries.

## Run

```sh
bash rnd/0.5.x/verify-quic-loss-l1.sh
```

## Expect

The PoC checks 17 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 5.1-5.3 RTT | first-sample reset, 7/8 smoothed, 3/4 rttvar, min_rtt, ack-delay subtract + cap |
| 6.1.1 packet threshold | 3-before -> lost, 2-before -> not, at/after largest -> not |
| 6.1.2 time threshold | 9/8 * max(smoothed, latest), granularity floor, old -> lost, recent -> not |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` with want / got and exits
non-zero.
