# tlz bench

What each tlz primitive costs on one core, measured by the four bench examples that ship with the package, next to `openssl speed` on the same machine.

This is not a gate. It is a reading taken on one machine, published so the method is repeatable and the gaps are visible. Rerun it on the target machine before deciding anything.

## What is measured

Four example binaries, each self-contained:

| Example | What it times |
| :- | :- |
| [`bench_rsa`](../examples/bench_rsa.zig) | one RSA sign over SHA-256 with 2048, 3072, and 4096 bit keys, PKCS#1 v1.5 and PSS |
| [`bench_ecdsa_p256`](../examples/bench_ecdsa_p256.zig) | one ECDSA P-256 SHA-256 sign |
| [`bench_ed25519`](../examples/bench_ed25519.zig) | one Ed25519 sign |
| [`bench_record`](../examples/bench_record.zig) | one full 16 KiB TLS 1.3 record under TLS_AES_128_GCM_SHA256, sealed by the server and opened by the client |

These are the operations a TLS server pays for: one sign per full handshake (CertificateVerify), and one seal or open per record after it.

The RSA keys are test keys made with `openssl genpkey` and live in `examples/certs/`. The ECDSA and Ed25519 keys are deterministic, built from a fixed seed.

## Method

- RSA: 100 signs per round. ECDSA and Ed25519: 10000 signs per round. Record: 4096 records per round, in batches of 64. 5 rounds per row.
- The quickest round is reported, not the mean. One round picks up whatever else the machine was doing.
- One untimed operation runs first per row, which warms the code path.
- Every signature is checked by the std verifier before any timing, and every opened record is compared with the sent bytes, so the tables time real work.
- RSA PSS uses a fixed salt, and ECDSA and Ed25519 sign without noise, so the random source stays out of the numbers.
- The record pair comes from a real in-memory TLS 1.3 handshake. Each row pays the full record path: header, inner content type byte, sequence nonce, AES-128-GCM, and the copy into the record buffer.
- The clock is the monotonic clock read through `std.Io`.

The reference commands:

```
openssl speed -seconds 3 rsa2048 rsa3072 rsa4096 ecdsap256 ed25519
openssl speed -seconds 3 -evp aes-128-gcm -bytes 16384
openssl speed -seconds 3 -evp aes-128-gcm -decrypt -bytes 16384
```

`openssl speed rsa` signs with PKCS#1 v1.5. `openssl speed -evp aes-128-gcm` times the raw AEAD with no record framing.

## System

| Item | Value |
| :- | :- |
| CPU | AMD Ryzen 5 5600H with Radeon Graphics |
| Architecture | x86_64 |
| CPU features used | aes, pclmulqdq, vaes, vpclmulqdq, avx2, adx |
| Cores / threads | 6 cores, 12 threads, 1 socket, 2 threads per core |
| Clock | 4280.98 MHz max, 412.63 MHz min |
| L1d / L1i cache | 192 KiB / 192 KiB (6 instances each) |
| L2 cache | 3 MiB (6 instances) |
| L3 cache | 16 MiB (1 instance) |
| Memory | 30 GiB |
| OS | Arch Linux |
| Kernel | Linux 7.2.14-arch1-1 x86_64 |
| Zig | 0.17.0 |
| OpenSSL | 3.6.5 |
| Build | `-Doptimize=ReleaseFast`, native target |
| CPU governor | powersave, energy preference balance_performance, boost on |

The box was not quiesced and the governor was not pinned to performance, so absolute numbers are conservative. The ratio column is what this page is for. Every bench runs on one thread, so only one core is used.

## How to read the columns

| Column | Better |
| :- | :- |
| ms/sign, us/sign, us/record | lower is better (less time per operation) |
| signs/s, MB/s | higher is better (more work per second) |
| ratio | higher is better (1.00x is the OpenSSL rate, above 1.00x is a higher rate than OpenSSL) |

## Result: RSA sign

The ratio is the tlz rate divided by the OpenSSL rate (1.00x means the same rate). Time columns: lower is better. Rate and ratio columns: higher is better.

| Key | Padding | tlz ms/sign | tlz signs/s | OpenSSL ms/sign | OpenSSL signs/s | ratio |
| :- | :- | :- | :- | :- | :- | :- |
| 2048 | PKCS#1 v1.5 | 0.507 | 1970.9 | 0.501 | 1994.3 | 0.99x |
| 2048 | PSS | 0.509 | 1962.9 | 0.501 | 1994.3 | 0.98x |
| 3072 | PKCS#1 v1.5 | 1.579 | 633.5 | 1.526 | 655.5 | 0.97x |
| 3072 | PSS | 1.577 | 634.1 | 1.526 | 655.5 | 0.97x |
| 4096 | PKCS#1 v1.5 | 3.359 | 297.7 | 3.457 | 289.3 | 1.03x |
| 4096 | PSS | 3.365 | 297.2 | 3.457 | 289.3 | 1.03x |

The PSS rows are compared with the OpenSSL PKCS#1 v1.5 rate. Both paddings run the same CRT private-key step, which is almost all of the cost, and the tlz rows show the two paddings within 1% of each other.

## Result: ECDSA P-256 and Ed25519 sign

Time columns: lower is better. Rate and ratio columns: higher is better.

| Key | tlz us/sign | tlz signs/s | OpenSSL us/sign | OpenSSL signs/s | ratio |
| :- | :- | :- | :- | :- | :- |
| ECDSA P-256 | 138.81 | 7204 | 16.53 | 60514 | 0.12x |
| Ed25519 | 50.69 | 19726 | 30.97 | 32292 | 0.61x |

## Result: record layer, AES-128-GCM, 16 KiB records

MB is 1,000,000 bytes of plaintext, the unit `openssl speed` prints. Time columns: lower is better. Rate and ratio columns: higher is better.

| Side | tlz us/record | tlz MB/s | OpenSSL us/record | OpenSSL MB/s | ratio |
| :- | :- | :- | :- | :- | :- |
| seal (encrypt) | 12.44 | 1317 | 3.06 | 5356 | 0.25x |
| open (decrypt) | 12.21 | 1342 | 3.11 | 5266 | 0.25x |

## Reading this

- RSA sign runs at the OpenSSL rate for all three key widths. This is the dedicated CRT signer in `src/crypto/rsa/crt.zig`. RSA is also the most expensive handshake key by far, so this is the row that moves full-handshake throughput most.
- ECDSA P-256 and Ed25519 come straight from `std.crypto`. tlz adds nothing on top of the sign call, so the gap is the std implementation. ECDSA P-256 is the larger gap (0.12x). Even with that gap, the per-sign cost on this machine orders Ed25519 (50.7 us), then ECDSA P-256 (138.8 us), then RSA-2048 (507 us), so for many full handshakes Ed25519 is the cheapest certificate key here.
- The record gap is the std AES-GCM, not the tlz framing. A one-off check of `std.crypto.aead.aes_gcm.Aes128Gcm` alone on the same 16 KiB input (not shipped) read about 1384 MB/s, so the record framing costs about 5% on top.
- The record rows depend on the build target. Without `aes` and `pclmulqdq` in the target, std AES-GCM falls back to software and the record layer becomes much slower. Build for the CPU the server runs on (native, or a named CPU that has these features).

| Situation | Reach for |
| :- | :- |
| many full handshakes per second | Ed25519 certificate, then ECDSA P-256, then RSA-2048 |
| large bodies over TLS | a build target with `aes` and `pclmulqdq` |
| a client that only offers RSA | RSA-2048, the rate matches OpenSSL |

## Reproducing

From the package root (`src/tlz`):

```
zig build examples -Doptimize=ReleaseFast
./zig-out/bin/tlz-example-bench_rsa-<arch>-<os>-fast
./zig-out/bin/tlz-example-bench_ecdsa_p256-<arch>-<os>-fast
./zig-out/bin/tlz-example-bench_ed25519-<arch>-<os>-fast
./zig-out/bin/tlz-example-bench_record-<arch>-<os>-fast
```

Run the benches one at a time, not in parallel, and run `openssl speed` the same way. A Debug build measures the safety checks rather than the primitives, so the optimize flag is not optional here.

The RSA keys are embedded at build time from `examples/certs/`. To measure other keys, replace those files with other PKCS#8 RSA keys of the same width.

## What these numbers do not say

- They are one machine and one core. Nothing here says what a server does under load, where the request path carries much more than crypto.
- They do not include the key exchange (X25519), the key schedule, or the certificate parse. A full handshake costs more than the sign row alone.
- The record rows use full 16 KiB records. Small records pay the fixed per-record cost more often, so their MB/s is lower.
- `openssl speed` times the raw AEAD, the tlz record rows time a full record. The ratio is slightly in favor of the reference for that reason.
