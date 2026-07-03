# Issue: TLS AES-GCM falls back to software when the build target lacks aes/pclmul

Date: 2026-06-26
Scope: 0.5.x, any zix TLS build whose CPU target does not include the `aes` and `pclmul` features.
Status: RESOLVED (root cause measured, fix verified end-to-end).

## Symptom

In HttpArena (local isolate run, 6 server cores), large-body TLS stalls while small-body TLS and all
cleartext profiles are fine.

| Profile | Port | TLS | Body | Result |
| :- | :- | :- | :- | :- |
| baseline-h2c, json-h2c | 8082 | no | any | fine |
| baseline-h2 | 8443 | yes | tiny | fine (about 580k req/s) |
| static-h2 | 8443 | yes | 6 to 67 KiB files | run 1 about 124s then the server wedges, runs 2 and 3 return 0 req/s |

The server burns about 6 cores (CPU 583%) yet completes almost nothing. Twelve TLS worker threads sit
on-CPU (`R`, no wait channel) with deep call stacks in the crypto region, while every connection's
kernel receive queue backs up (the workers are too busy encrypting to read). ref-server and ref-server-2 pass
the same static-h2 at 2.2 GB/s and 3.9 GB/s.

## Root cause

`std.crypto.aead.aes_gcm.Aes128Gcm` selects the hardware or software backend at COMPILE time:
`src/tls/record.zig` uses it, and `std.crypto/aes.zig` gates the AES-NI path on
`builtin.cpu.has(.x86, .aes)` plus `avx`. The two heavy halves of AES-GCM each need a CPU feature:

| Part | Instruction set | Zig feature |
| :- | :- | :- |
| AES block cipher | AES-NI | `aes` |
| GHASH authentication | carry-less multiply (PCLMULQDQ) | `pclmul` |

The HttpArena entry Dockerfile builds `-Dcpu=x86_64_v3`. The `x86_64_v3` microarchitecture level does
NOT include `aes` or `pclmul` (they are separate optional features, not part of any `x86_64_vN` level).
So zix compiles the pure-software AES plus software GHASH. baseline-h2 hides it (tiny bodies keep up),
static-h2 exposes it (large bodies saturate the software cipher, the worker never returns to read).

## Measured (AES-128-GCM, 16 KiB blocks, one core, zig-0.16 musl ReleaseFast)

| Build target | Backend | Throughput |
| :- | :- | -: |
| `x86_64_v3` (the container build) | software | 87 MB/s |
| `x86_64_v3+aes+pclmul` | hardware AES-NI | 3742 MB/s |

43x. The software 87 MB/s, spread over the container's effective cores, matches the observed about
143 MB/s aggregate.

## Fix

Build with a CPU target that includes the features. In the entry Dockerfile, `x86_64_v3` becomes
`x86_64_v3+aes+pclmul`. Safe: every `x86_64_v3`-capable CPU has AES-NI and
PCLMUL (both shipped years before AVX2), so v3 portability is unchanged. On aarch64 the equivalent is
`+aes` (ARM Crypto Extensions, no `pclmul` there).

This applies to EVERY zix TLS surface, not just http2: grpc-tls, json-tls, and http3 (TLS-mandatory)
are all on the same software fallback when built without the features.

## Verified (end-to-end)

Rebuilt the entry with `+aes+pclmul`, ran the exact stalling pattern (`-c 512 -m 32 -i`, the 20-file
static set) with the server pinned to 2 cores:

| Build | Result |
| :- | :- |
| `x86_64_v3` (software) | run 1 about 124s, then wedged |
| `x86_64_v3+aes+pclmul` (hardware) | 51200 requests in 2.76s, 0 errored, 0 timeout |

On the 6-core HttpArena run, static-h2 then completed 3/3 at about 124k req/s and 1.9 GB/s (between
ref-server-2 and ref-server), and baseline-h2 rose from about 580k to about 706k req/s from the same change.

## Note on the parallel fixes

The software-AES build flag was the static-h2 blocker. Three TLS-path bugs were found and fixed along
the way (real correctness issues the AES stall had masked, kept regardless):

1. `tls_mux.zig` staging length tracked the allocation capacity, not the live byte count, so a grown
   backpressure buffer flushed its uninitialized tail as ciphertext.
2. `sendRaw` wrote a new record directly to the socket even when earlier ciphertext was staged, so
   records could reach the peer out of order (TLS requires in-order records, the nonce is the record
   sequence number).
3. The HttpArena entry warmed its static cache lazily under a spinlock held across the file read, which
   livelocked the oversubscribed worker pool on a cold cache. The entry now pre-warms at startup.
