# Issue: RSA TLS handshake is CPU-bound, stalls h2/grpc-over-TLS at high concurrency

Date: 2026-06-25
Scope: 0.5.x, the multiplexed TLS dispatch (tls_epoll) under the HttpArena musl ReleaseFast build.

## Symptom

In HttpArena (local isolate run, 6 server cores), every h2/grpc-over-TLS profile stalls at high
concurrency, while the cleartext h2c profiles are fine.

| Profile | Port | TLS | Concurrency | Result |
| :- | :- | :- | :- | :- |
| baseline-h2c, json-h2c | 8082 | no | 512c+ | fine |
| static-h2 | 8443 | yes | 512c | stall |
| baseline-h2 | 8443 | yes | 512c | stall (same path) |
| unary-grpc-tls | 8443 | yes | 256c slow, 1024c stall | stall |

The only difference between the working and stalling profiles is TLS on port 8443.

## Confirmed (direct evidence)

1. The stall is CPU-bound on connection establishment, not on request serving.
   static-h2 512c: CPU 587.9% (about 6 cores pegged), connect mean 3.97s, max 7.18s, run 1 finished
   in 203.64s, runs 2 and 3 returned 0 req/s (the server never recovered). When a connection does
   establish, serving is healthy (unary-grpc-tls 256c sustained 414k req/s).
2. The multiplexed tls_epoll dispatch IS engaged (the dispatch_model fix landed). Proof: grpc-tls
   256c connect dropped from 1.48s (the old thread-per-conn terminator) to 841ms (multiplexed). So
   the stall is not the old thread-per-conn thrash, it is a new, CPU-bound handshake bottleneck.
3. The handshake performs an RSA-2048 private-key operation. src/tls/rsa.zig signs via a single
   full-width constant-time modular exponentiation (std.crypto.ff.Modulus) with the 2048-bit private
   exponent, and skips CRT (rsa.zig: the CRT primes p, q, dP, dQ, qInv are parsed-over, not retained).
   A non-CRT sign is about 4x a CRT sign, and an RSA sign with the full private exponent is about
   120x an RSA verify (which uses the tiny public exponent).
4. The handshake runs inline on the epoll worker. A slow sign blocks the event loop, so the loop
   cannot service other connections' handshake round-trips or established traffic. h2load times out
   on connect, reconnects, and the handshake backlog spirals (the 203s and the 0 req/s reruns).
5. The native (glibc, non-container) ReleaseFast build does NOT reproduce the stall: the same
   tls_epoll path served grpc-tls 1024c at 712k req/s with no stall. So the stall is specific to the
   HttpArena build or environment.

## Measured (RSA-2048 signPss, 200 iterations, one core)

A microbenchmark of the sign path, built for the container config and for native:

| build | plain m ^ d | CRT | speedup |
| :- | :- | :- | :- |
| musl x86_64_v3 ReleaseFast (the container) | 14.17 ms | 4.46 ms | 3.18x |
| native ReleaseFast | 14.49 ms | 4.52 ms | 3.21x |

Conclusions, now measured:
1. H1 CONFIRMED: a single RSA-2048 sign is about 14 ms on the plain path, the dominant handshake cost.
2. H2 REFUTED: musl and native are within about 1 percent. libc does not matter, and the CPU target
   (x86_64_v3 vs native) does not matter for this code. So glibc would NOT fix the stall. The
   native-vs-container difference observed earlier was not sign speed. The remaining candidate is the
   worker count and h2load's connect-timeout margin: native saw 12 logical CPUs (12 signing workers),
   the container's cgroup cpuset gives 6, so the container has half the handshake throughput and tips
   into the reconnect spiral while native stays under the timeout.
3. CRT cuts the sign to 4.46 ms (3.18x). At 6 workers that is about 6 * (1000 / 4.46) = 1344 signs per
   second, so 1024 connections handshake in about 0.76s, which should clear h2load's connect window
   and break the spiral.

## Still NOT measured

- End-to-end: that CRT actually clears the 512c / 1024c stall in the container. The math above says it
  should, but the grpc musl ReleaseFast build is too slow to iterate locally (15+ minutes), so the
  end-to-end confirmation is the next container rebuild. If CRT alone does not fully clear it (the
  6-worker margin is tight), the offload lever below is the guaranteed backstop.

## Levers (once the hypothesis is measured)

1. CRT in src/tls/rsa.zig: retain p, q, dP, dQ, qInv in the key parser, sign as two ~1024-bit modexps
   plus Garner recombination, still constant-time via ff.Modulus per prime. About 4x faster, fixes
   every RSA TLS handshake (thread-per-conn path too), contained to one file.
2. Offload the sign off the epoll loop: a bounded handshake pool, so a slow sign never blocks serving
   and the backlog cannot spiral. Architectural, larger change, needed only if a faster sign is not
   enough on its own.

## Next step (to confirm before fixing)

Build the example for the container target (zig build ... -Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3
--release=fast) and:
1. Measure the per-sign wall-time (microbenchmark the signPss path).
2. Reproduce the 512c / 1024c stall locally with the RSA cert, to get a before-baseline.
3. Then decide CRT, or CRT plus offload, and gate the fix against this musl reproduction (native is
   too fast to reproduce the stall).
