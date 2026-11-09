# jzon benchmark

What each jzon path costs on one record, measured by the two bench examples that ship with the package.

This is not a gate. It is a reading taken on one machine with one record, published so the method is repeatable and the shape of the trade is visible. Rerun it on the shape being served before deciding anything.

## What is measured

Two example binaries, each self-contained:

| Example | What it times |
| :- | :- |
| [`bench_serialize`](../examples/bench_serialize.zig) | one record rendered through every JSON write strategy and both ZON layouts |
| [`bench_deserialize`](../examples/bench_deserialize.zig) | one record parsed through every JSON read strategy (minified and laid out), through ZON (both layouts), and read from a real file against parsed |

Both run over the same record: an unsigned integer, a string, an exhaustive enum, an optional string, a string array, and a slice of two nested structs holding a string, an unsigned integer, and a signed integer.

## Method

- 100000 operations per round, 5 rounds per row.
- The quickest round is reported, not the mean. One round picks up whatever else the machine was doing.
- One untimed operation runs first per row, which warms the code path.
- The serialize bench asserts all four JSON write paths render identical bytes before any timing starts, so the JSON rows compare equal work.
- The deserialize bench checks the parsed shape once per row, so a path that read less cannot go untimed.
- The arena reset sits inside the timed deserialize loop on purpose. It is what a worker pays per request, and every row pays it equally.
- Strings are copied, which is the default. Borrowing is a separate lever, shown in `examples/strings.zig`.
- The file rows read `examples/order.json` and `examples/order.zon` with one `readFileAlloc` per operation. The parse-only row parses the same bytes the file holds.
- The clock is the monotonic clock read through `std.Io`.

## System

| Item | Value |
| :- | :- |
| CPU | AMD Ryzen 5 5600H with Radeon Graphics |
| Architecture | x86_64 |
| Cores / threads | 6 cores, 12 threads, 1 socket, 2 threads per core |
| Clock | 4280.98 MHz max, 412.63 MHz min |
| L3 cache | 16 MiB |
| Memory | 30 GiB |
| OS | Arch Linux |
| Kernel | Linux 7.2.14-arch1-1 x86_64 |
| Zig | 0.17.0 |
| Build | `-Doptimize=ReleaseFast`, native target |
| CPU governor | powersave, energy preference balance_performance, boost on |

The box was not quiesced and the governor was not pinned to performance, so absolute numbers are conservative. The ratios between rows are what this table is for, and they held across repeated runs.

## Result: serialize

Record rendered to 208 bytes of JSON. Every JSON path produced identical bytes.

| Path | ns/render | renders/s | vs default |
| :- | :- | :- | :- |
| JSON `.STD` | 322 | 3104655 | 1.00x |
| JSON `.GENERATED_FMT` | 98 | 10218641 | 3.29x |
| JSON `.GENERATED` | 93 | 10768555 | 3.47x |
| JSON `.GENERATED_VECTOR` | 99 | 10139825 | 3.27x |
| ZON `.MULTILINE` | 117 | 8520924 | 2.74x |
| ZON `.COMPACT` | 112 | 8919532 | 2.87x |

What this shows:

- Most of the JSON gain arrives with the generated emitter itself: `.GENERATED_FMT` is already 3.29x the default's rate, and it still formats integers through `std.fmt`. That is the object-key punctuation collapsing into one comptime literal per field.
- Writing digits straight into the buffer adds a little more (3.47x). The vector escape scan is level with the scalar one here, because the record's strings are short and a lane buys about one comparison.
- ZON runs one generated path, built the same way: every `.name = ` is one comptime literal. It writes more bytes than JSON for the same record (indent, spaces around `=`), which is most of the gap to JSON `.GENERATED`.

## Result: JSON deserialize, minified

Document of 208 bytes, no whitespace, which is what arrives off a wire.

| Strategy | ns/parse | parses/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 917 | 1090781 | 1.00x |
| `.SCANNER` | 933 | 1071975 | 0.98x |
| `.GENERATED` | 263 | 3809369 | 3.49x |
| `.GENERATED_VECTOR` | 268 | 3733694 | 3.42x |

## Result: JSON deserialize, laid out

The same value, pretty printed to 257 bytes.

| Strategy | ns/parse | parses/s | vs default |
| :- | :- | :- | :- |
| `.STD` | 979 | 1021912 | 1.00x |
| `.SCANNER` | 982 | 1018271 | 1.00x |
| `.GENERATED` | 281 | 3564767 | 3.49x |
| `.GENERATED_VECTOR` | 302 | 3309182 | 3.24x |

What this shows:

- `.SCANNER` moves the field dispatch to compile time but leaves tokenizing to `std.json.Scanner`, which is where the read cost sits. On this record the dispatch alone is worth about nothing.
- `.GENERATED` owns the whole read: the grammar, the scan, the escape decoding, and the dispatch. That is 3.49x on both shapes, because stepping over whitespace is cheap when nothing else reflects.
- `.GENERATED_VECTOR` is level with `.GENERATED` on minified text and a little behind on laid-out text. The record's whitespace runs are short (two to four spaces), so a lane rarely pays. It is a choice to measure on documents with long whitespace runs or long strings.

## Result: ZON deserialize

The same value as ZON: the multiline file (`examples/order.zon`, 461 bytes with its comment) and the same value on one line.

| Layout | ns/parse | parses/s | vs multiline |
| :- | :- | :- | :- |
| multiline | 727 | 1376019 | 1.00x |
| compact | 624 | 1602964 | 1.16x |

ZON reads at about 0.37x the rate of JSON `.GENERATED`. The text is longer, and every number goes through `std.zig.parseNumberLiteral` before `std.fmt` converts it, so the Zig grammar decides what a valid number is.

## Result: file read against parse

One `readFileAlloc` per operation, then the parse, with the arena reset after each.

| File | Parse only | Read only | Read + parse |
| :- | :- | :- | :- |
| `examples/order.json` (259 bytes, JSON `.GENERATED`) | 278 ns | 3927 ns | 4452 ns |
| `examples/order.zon` (461 bytes) | 739 ns | 3998 ns | 4998 ns |

Reading the file costs 5 to 14 times the parse. For a config file read once at start, the format and the path do not matter. For data read per request, keep the bytes in memory and parse the slice.

## Reading this

The JSON default is the capable path, not the slow one to be escaped from. It takes every shape std takes, and on this record it still turns over 3.1 million renders and 1.0 million parses per second on one core.

A generated strategy is what a call site opts into once its shape is known to be a plain record and the call is on the request path:

| Situation | Reach for |
| :- | :- |
| any shape, no measurement yet | `.{}` |
| a plain record on the request path | `.strategy = .GENERATED` on both sides |
| the value dies with the buffer it was read out of | add `.strings = .BORROW` |
| long text fields or long whitespace runs | measure `.GENERATED_VECTOR` |
| a config file written by people | `jzon.zon`, read once |

## Reproducing

From the package root (`src/jzon`):

```
zig build example-bench_serialize example-bench_deserialize -Doptimize=ReleaseFast
./zig-out/bin/jzon-example-bench_serialize-<arch>-<os>-fast
./zig-out/bin/jzon-example-bench_deserialize-<arch>-<os>-fast
```

Run them from `src/jzon`, because the file rows read `examples/order.json` and `examples/order.zon` by relative path. A Debug build measures the safety checks rather than the paths and collapses the rows onto each other, so the optimize flag is not optional here.

To measure a different record, edit the `Order` type and the payload constants at the top of each bench file, and the two files in `examples/`. The iteration count and round count are constants in the same place.

## What these numbers do not say

- They are one record on one machine. A shape with longer strings, more integers, or deeper nesting moves which path costs least.
- They are single threaded and in process. Nothing here says what a server does under load, where the request path carries a great deal besides JSON.
- They say nothing about memory. Borrowing strings instead of copying them is the lever that moves that, and it is not on this axis.
- The file rows run with the file in the page cache. A cold read from disk costs more.
