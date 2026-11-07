# uuidz low-level design

This document covers the byte-level and internal detail. For the shape of the library read `hld-en.md` first.

<br>

## The hex alphabet

`hex.zig` owns one constant:

```zig
pub const hex = "0123456789abcdef";
```

Every string conversion uses it. There is no second copy of the alphabet anywhere in the library.

<br>

## UUID v1

### Bit layout

A v1 UUID is 16 bytes, big-endian across the fields:

| Bytes | Field | Width |
| :- | :- | :- |
| 0-3 | time_low | 32 bits |
| 4-5 | time_mid | 16 bits |
| 6-7 | time_high_and_version | 16 bits (version in the high nibble) |
| 8 | clock_seq_high_and_reserved | 8 bits (variant in the high bits) |
| 9 | clock_seq_low | 8 bits |
| 10-15 | node | 48 bits |

The version nibble is `0x1`. The variant bits are `10` (RFC 4122), so byte 8 has its top two bits set to `10`.

<br>

### Generation

`init` locks a mutex, then runs the following once per process:

1. Fill `node` with 6 secure random bytes. Set the multicast bit (`node[0] |= 0x01`) so the node is not a real MAC address.
2. Fill `clock_sequence` with 14 bits from two secure random bytes.

Then for every call:

1. Read the clock as nanoseconds.
2. Divide by 100 to get 100-nanosecond intervals, then add `UUID_EPOCH_OFFSET` (the difference between the UUID epoch and the Unix epoch).
3. If the timestamp is not greater than `last_timestamp`, increment `clock_sequence` and wrap at 14 bits. This keeps the identifier monotonic when the clock stands still or moves backward.
4. Store the new timestamp.
5. Split the timestamp into the three time fields.
6. OR the version nibble into `time_high_and_version`.
7. OR the variant bits into `clock_seq_high_and_reserved`.
8. Write the fields into `data` in big-endian order.

The mutex covers the whole call, so two threads cannot read the shared `clock_sequence` or `last_timestamp` at the same time.

### Parsing

`initFromString` accepts 36 or 32 characters. For the 36-character form it requires a hyphen at positions 8, 13, 18, and 23. For the 32-character form it reads the hex digits directly.

Each byte is decoded from two hex characters. Upper and lower case are both accepted. A character outside the hex set is `InvalidHexCharacter`.

After the 16 bytes are filled, v1 performs no version check. The v1 parser accepts any UUID shape. If strict version enforcement is wanted, the caller checks the version nibble.

<br>

## UUID v4

### Bit layout

A v4 UUID is 16 random bytes with two masked regions:

| Bytes | Content |
| :- | :- |
| 0-15 | Random |
| 6 (high nibble) | `0x4` (version 4) |
| 8 (top two bits) | `10` (RFC 4122 variant) |

### Generation

`init` fills all 16 bytes with secure random data, then masks:

```zig
self.data[6] = (self.data[6] & 0x0F) | 0x40;
self.data[8] = (self.data[8] & 0x3F) | 0x80;
```

No mutex is needed because no shared state is touched.

### Parsing

The parse path is the same 16-byte hex walk as v1, with one addition: after decoding, v4 checks that byte 6 has the version nibble `0x4` and byte 8 has the variant bits `10`. A mismatch is `InvalidUuidVersion` or `InvalidUuidVariant`.

This strict check means a v1 string handed to `v4.initFromString` is rejected rather than silently reinterpreted.

<br>

## UUID v7

### Bit layout

A v7 UUID is 16 bytes:

| Bytes | Field | Width |
| :- | :- | :- |
| 0-5 | unix_ts_ms | 48 bits |
| 6 (high nibble) | version | 4 bits (`0x7`) |
| 6 (low nibble) - 15 | random | 74 bits |
| 8 (top two bits of the random) | variant | 2 bits (`10`) |

### Generation

`init` locks a mutex for the whole call. The flow is:

1. Read the clock in milliseconds.
2. If the clock moved backward (`current_ms < last_timestamp_ms`), pin `current_ms` to `last_timestamp_ms`. This is the NTP-sync guard.
3. If `current_ms` is strictly greater than `last_timestamp_ms`, fill the 74-bit random field with secure random data and store the new timestamp.
4. If `current_ms` equals `last_timestamp_ms`, increment the 74-bit random field as a big-endian counter. This keeps identifiers generated in the same millisecond monotonically increasing.
5. After the increment, compare the new random field with the old one. If it did not grow (meaning the 74-bit counter overflowed), add one millisecond to `current_ms`, re-randomize the field, and store the new timestamp.
6. Apply the version and variant masks.
7. Write the 48-bit timestamp into bytes 0-5 in big-endian order.

The mutex covers the shared `last_timestamp_ms` and the shared monotonicity state.

### Parsing

The parse path is the same 16-byte hex walk, with two checks after decoding:

- Byte 6 must have the version nibble `0x7`.
- Byte 8 must have the variant bits `10`.

A mismatch is `InvalidUuidVersion` or `InvalidUuidVariant`.

<br>

## String formatting

Both `asString` and `asReffID` use the same inner loop: for each of the 16 bytes, write the high nibble's hex character, then the low nibble's.

The difference is the separator:

| Call | Buffer size | Separator |
| :- | :- | :- |
| `asString` | 36 | `-` after byte 3, 5, 7, and 9 |
| `asReffID` | 32 | none |

The loops are `inline for`, so the boundaries are compile-time constants and the compiler sees a fixed sequence of stores with no runtime branch on the index.

<br>

## The mutex

v1 and v7 share mutable state (`clock_sequence`, `last_timestamp`, `last_timestamp_ms`, `node`, `is_initialized`). Both use a `std.Io.Mutex` declared as a file-scope variable inside the version struct.

The pattern is always the same:

```zig
try mutex.lock(io);
defer mutex.unlock(io);
```

The `defer` is the guard. There is no path that returns without unlocking.

<br>

## Integer reads and writes

The timestamp is written with `std.mem.writeInt` in big-endian order, so the bytes in `data` match the RFC layout without a manual shift sequence.

The v7 timestamp is written byte by byte from a `u64`, shifting right by 40, 32, 24, 16, 8, and 0. This is the same big-endian order in an explicit form.

<br>

## Error handling

No error is swallowed. Every `try` propagates to the caller, and every version-specific validation returns a named error from the same parse set. The generation path has no validation because the masks are applied unconditionally.
