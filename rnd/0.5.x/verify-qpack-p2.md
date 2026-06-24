# Verify: QPACK dynamic table + Required Insert Count (http3-plan.md phase P2)

P1 was the static half. P2 adds the dynamic table: a bounded, append-with-eviction store the encoder
fills at runtime, plus the Required Insert Count / Base transform the field section prefix uses to
name how much of the dynamic table a header block depends on.

## Oracle

RFC 9204 section 3.2 + section 4.5.1:

- 3.2.1 fixes the entry size: name length + value length + 32, using unencoded lengths. 3.2.2 fixes
  eviction: before inserting, entries are evicted from the oldest end until the new entry fits, and
  an entry larger than the whole capacity is a QPACK_ENCODER_STREAM_ERROR. 3.2.4 fixes absolute
  indexing: the first insert is index 0, increasing by one and never reused. Reducing capacity (to 0
  clears the table) evicts from the oldest end.
- 4.5.1.1 fixes the Required Insert Count transform. Both RFC worked-example values are checked: a
  100-byte table gives MaxEntries 3, so RIC 9 encodes to 4 and (with 10 inserts received) decodes
  back to 9, and an out-of-range encoded value is a QPACK_DECOMPRESSION_FAILED. 4.5.1.2 fixes Base:
  RIC 9 with Sign 1 / Delta Base 2 resolves to Base 6.

No external tool is used at this layer. P4 is where the cross-implementation .qif interop begins.

## Run

```sh
bash rnd/0.5.x/verify-qpack-p2.sh
```

## Expect

The PoC checks 20 values and prints `ok` for each:

| Group | Checks |
| :- | :- |
| 3.2.1 entry size | name + value + 32, empty = 32 |
| 3.2.2 / 3.2.4 table | insert + size, eviction of oldest, oversized reject, capacity reduce + clear |
| 4.5.1.1 RIC | MaxEntries, encode 0 + 9, decode 4 -> 9, out-of-range reject |
| 4.5.1.2 Base | Sign 0 add, Sign 1 subtract |

On success the script prints `PASS` and exits 0. Any failure prints `FAIL` and exits non-zero.
