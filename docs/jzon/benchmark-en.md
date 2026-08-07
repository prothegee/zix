# jzon benchmark

What each jzon path costs on one record, measured by the two bench examples that ship with the package.

This is not a gate. It is a reading taken on one machine with one record, published so the method is repeatable and the shape of the trade is visible. Rerun it on the shape being served before deciding anything.

## What is measured

Two example binaries, each self-contained:

| Example | What it times |
| :- | :- |
| [`bench_serialize`](../../src/jzon/examples/bench_serialize.zig) | one record rendered through every write strategy |
| [`bench_deserialize`](../../src/jzon/examples/bench_deserialize.zig) | one document parsed through every read strategy, minified and laid out |

Both run over the same record: an unsigned integer, a string, an exhaustive enum, an optional string, a string array, and a slice of two nested structs holding a string, an unsigned integer, and a signed integer.

## Method

- 100000 operations per round, 5 rounds per path.
- The quickest round is reported, not the mean. One round picks up whatever else the machine was doing.
- One untimed operation runs first per path, which warms the code path and produces the value every timed operation is checked against.
- The serialize bench asserts all four write paths render identical bytes before any timing starts, so the table compares equal work.
- The deserialize bench checks the parsed shape once per path, so a path that read less cannot go untimed.
- The arena reset sits inside the timed deserialize loop on purpose. It is what a worker pays per request, and every row pays it equally.
- Strings are copied, which is the default. Borrowing is a separate lever, shown in `examples/strings.zig`.
- The clock is the monotonic clock (`CLOCK_MONOTONIC` on Linux) read through `std.Io`.

## System

| Item | Value |
| :- | :- |
| CPU | AMD Ryzen 5 5600H with Radeon Graphics |
| Architecture | x86_64 |
| Cores / threads | 6 cores, 12 threads, 1 socket, 2 threads per core |
| Clock | 4280.98 MHz max, 412.63 MHz min |
| L3 cache | 16 MiB |
| Relevant ISA | avx2, sse4_2, aes, pclmulqdq, sha_ni |
| Memory | 30.7 GiB |
| OS | Arch Linux |
| Kernel | Linux 7.1.5-arch1-2 x86_64 |
| Zig | 0.16.0 |
| Build | `-Doptimize=ReleaseFast`, native target |
| CPU governor | powersave, energy preference balance_performance, boost on |

The box was not quiesced and the governor was not pinned to performance, so absolute numbers are conservative. The ratios between rows are what this table is for, and they held across repeated runs.

## Result: serialize

Record rendered to 208 bytes. Every path produced identical bytes.

| Strategy | ns/render | renders/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 319 | 3138976 | 1.00x |
| `.GENERATED_FMT` | 101 | 9873387 | 3.15x |
| `.GENERATED` | 74 | 13516564 | 4.31x |
| `.GENERATED_VECTOR` | 75 | 13410095 | 4.27x |

Two things this shows:

- Most of the gain arrives with the generated emitter itself, before any integer trick: `.GENERATED_FMT` is already 3.15x the default's rate, and it still formats integers through `std.fmt`. That is the object-key punctuation collapsing into one comptime literal per field.
- Writing digits straight into the buffer adds the rest, from 3.15x to 4.31x. The digit conversion is identical in both paths, so what that step buys is dropping the per-call `std.Io.Writer` setup, the width and alignment pass, and the error union at every call site.
- The vector escape scan is level with the scalar one here (4.27x against 4.31x). The record's strings are short, so a lane buys about one comparison.

## Result: deserialize, minified

Document of 208 bytes, no whitespace, which is what arrives off a wire.

| Strategy | ns/parse | parses/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 1212 | 825184 | 1.00x |
| `.SCANNER` | 1082 | 924623 | 1.12x |
| `.GENERATED` | 271 | 3688013 | 4.47x |
| `.GENERATED_VECTOR` | 374 | 2671197 | 3.24x |

## Result: deserialize, laid out

The same value, pretty printed to 257 bytes.

| Strategy | ns/parse | parses/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 1245 | 803165 | 1.00x |
| `.SCANNER` | 1123 | 890708 | 1.11x |
| `.GENERATED` | 294 | 3403677 | 4.24x |
| `.GENERATED_VECTOR` | 635 | 1574325 | 1.96x |

Three things this shows:

- `.SCANNER` moves the field dispatch to compile time but leaves tokenizing to `std.json.Scanner`, which is where the read cost sits. 1.12x is what the dispatch alone is worth.
- `.GENERATED` owns the whole read: the grammar, the scan, the escape decoding, and the dispatch. That is 4.47x on minified traffic and it barely moves when whitespace is added, because stepping over whitespace is cheap when nothing else reflects.
- `.GENERATED_VECTOR` costs on both shapes here, and costs most on the laid-out one: 1.96x against `.GENERATED`'s 4.24x. This is the opposite of what a whitespace-skipping vector scan is meant to do, and it is worth reading as an open question about the read-side scan rather than as a property of vector scanning. The bench prints both shapes precisely so this stays visible rather than averaged away.

## Reading this

The default is the capable path, not the slow one to be escaped from. It takes every shape std takes, and on this record it still turns over 3.1 million renders and 825 thousand parses per second on one core.

A generated strategy is what a call site opts into once its shape is known to be a plain record and the call is on the request path. The numbers above suggest the ordering:

| Situation | Reach for |
| :- | :- |
| any shape, no measurement yet | `.{}` |
| a plain record on the request path | `.strategy = .GENERATED` on both sides |
| the value dies with the buffer it was read out of | add `.strings = .BORROW` |
| long text fields being rendered | measure `.GENERATED_VECTOR` on the write side |

## Reproducing

From the package root:

```
zig build example-bench_serialize example-bench_deserialize -Doptimize=ReleaseFast
./zig-out/bin/jzon-example-bench_serialize-<arch>-<os>
./zig-out/bin/jzon-example-bench_deserialize-<arch>-<os>
```

A Debug build measures the safety checks rather than the paths and collapses the rows onto each other, so the optimize flag is not optional here.

To measure a different record, edit the `Order` type and the payload constants at the top of each bench file. The iteration count and round count are constants in the same place.

## What these numbers do not say

- They are one record on one machine. A shape with longer strings, more integers, or deeper nesting moves which path costs least.
- They are single threaded and in process. Nothing here says what a server does under load, where the request path carries a great deal besides JSON.
- They say nothing about memory. Borrowing strings instead of copying them is the lever that moves that, and it is not on this axis.
