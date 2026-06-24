//! QPACK PoC, phase P2 (http3-plan.md): RFC 9204 section 3.2 (dynamic table size, capacity,
//! eviction, indexing) and 4.5.1 (Required Insert Count and Base).
//!
//! Note:
//! - P1 was the static half. P2 adds the dynamic table: a bounded, append-only-with-eviction store
//!   the encoder fills at runtime. The size accounting (each entry costs name + value + 32 bytes),
//!   the eviction-from-the-oldest-end rule, and the absolute index that never reuses a value are the
//!   core. On top sits the Required Insert Count / Base transform that the field section prefix uses
//!   to name how much of the dynamic table a header block depends on.
//! - The oracle is the RFC text and its two worked examples: a 100-byte table gives MaxEntries 3, so
//!   a Required Insert Count of 9 encodes to 4 and (with 10 inserts received) decodes back to 9
//!   (4.5.1.1), and a Required Insert Count of 9 with Sign 1 / Delta Base 2 resolves to Base 6
//!   (4.5.1.2). The sizing and eviction are exercised on a crafted table in process.
//! - Adding an entry larger than the capacity is a QPACK_ENCODER_STREAM_ERROR, and an
//!   unreconstructable Required Insert Count is a QPACK_DECOMPRESSION_FAILED, both checked.
//!
//! Run:    zig run rnd/0.5.x/qpack_p2_poc.zig
//! Verify: bash rnd/0.5.x/verify-qpack-p2.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// The per-entry overhead in the dynamic table size accounting (RFC 9204 3.2.1).
const entry_overhead: usize = 32;

/// The size of a dynamic table entry (RFC 9204 3.2.1): name length + value length + 32, using the
/// unencoded (non-Huffman) lengths.
fn entrySize(name: []const u8, value: []const u8) usize {
    return name.len + value.len + entry_overhead;
}

/// One dynamic table entry.
const DynEntry = struct { name: []const u8, value: []const u8 };

/// The errors the QPACK dynamic table raises (RFC 9204 3.2.2).
const TableError = error{
    /// Inserting an entry larger than the capacity: QPACK_ENCODER_STREAM_ERROR.
    EncoderStreamError,
};

/// The QPACK dynamic table (RFC 9204 3.2): a bounded store, oldest entries evicted from the end to
/// make room. Entries are kept oldest-first, so the oldest (lowest absolute index) is at the front.
const DynamicTable = struct {
    capacity: usize,
    items: [64]DynEntry = undefined,
    count: usize = 0,
    size: usize = 0,
    inserts: u64 = 0,

    /// Insert a new entry, evicting from the oldest end first (RFC 9204 3.2.2). An entry larger than
    /// the capacity is a QPACK_ENCODER_STREAM_ERROR.
    fn insert(self: *DynamicTable, name: []const u8, value: []const u8) TableError!void {
        const need = entrySize(name, value);
        if (need > self.capacity) return error.EncoderStreamError;

        while (self.size + need > self.capacity) self.evictOldest();

        self.items[self.count] = .{ .name = name, .value = value };
        self.count += 1;
        self.size += need;
        self.inserts += 1;
    }

    /// Evict the oldest entry from the front (RFC 9204 3.2.2).
    fn evictOldest(self: *DynamicTable) void {
        const gone = entrySize(self.items[0].name, self.items[0].value);
        for (1..self.count) |i| self.items[i - 1] = self.items[i];

        self.count -= 1;
        self.size -= gone;
    }

    /// Reduce or raise the capacity, evicting from the oldest end until the size fits (RFC 9204
    /// 3.2.2). A capacity of 0 clears the table.
    fn setCapacity(self: *DynamicTable, new_capacity: usize) void {
        self.capacity = new_capacity;
        while (self.size > self.capacity) self.evictOldest();
    }

    /// The absolute index of the oldest live entry (RFC 9204 3.2.4): inserts so far minus live count.
    fn oldestAbsoluteIndex(self: DynamicTable) u64 {
        return self.inserts - self.count;
    }

    /// MaxEntries for the current capacity (RFC 9204 4.5.1.1): floor(capacity / 32).
    fn maxEntries(self: DynamicTable) u64 {
        return self.capacity / entry_overhead;
    }
};

// --------------------------------------------------------------- //

/// The errors Required Insert Count reconstruction raises (RFC 9204 4.5.1.1).
const RicError = error{
    /// An EncodedInsertCount no conformant encoder could produce: QPACK_DECOMPRESSION_FAILED.
    DecompressionFailed,
};

/// Transform a Required Insert Count for the wire (RFC 9204 4.5.1.1): 0 stays 0, otherwise it is
/// taken modulo twice MaxEntries and offset by one to bound the prefix length.
fn encodeRequiredInsertCount(ric: u64, max_entries: u64) u64 {
    if (ric == 0) return 0;

    return (ric % (2 * max_entries)) + 1;
}

/// Reconstruct the Required Insert Count from the wire value (RFC 9204 4.5.1.1), given the total
/// inserts the decoder has made. An unreconstructable value is a QPACK_DECOMPRESSION_FAILED.
fn decodeRequiredInsertCount(encoded: u64, total_inserts: u64, max_entries: u64) RicError!u64 {
    if (encoded == 0) return 0;

    const full_range = 2 * max_entries;
    if (encoded > full_range) return error.DecompressionFailed;

    const max_value = total_inserts + max_entries;
    const max_wrapped = (max_value / full_range) * full_range;
    var ric = max_wrapped + encoded - 1;

    if (ric > max_value) {
        if (ric <= full_range) return error.DecompressionFailed;
        ric -= full_range;
    }
    if (ric == 0) return error.DecompressionFailed;

    return ric;
}

/// Resolve the Base from the Required Insert Count, the Sign bit, and Delta Base (RFC 9204 4.5.1.2).
/// Sign 0 adds Delta Base, Sign 1 subtracts Delta Base and one.
fn resolveBase(ric: i64, sign: bool, delta_base: i64) i64 {
    return if (sign) ric - delta_base - 1 else ric + delta_base;
}

// --------------------------------------------------------------- //

/// Report a boolean expectation and flag a failure.
fn expect(failures: *usize, name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        failures.* += 1;
    }
}

pub fn main() !void {
    var failures: usize = 0;

    std.debug.print("RFC 9204 3.2.1: entry size accounting\n", .{});

    expect(&failures, "entry size foo/bar = 3 + 3 + 32 = 38", entrySize("foo", "bar") == 38);
    expect(&failures, "empty entry size = 32", entrySize("", "") == 32);

    std.debug.print("RFC 9204 3.2.2 / 3.2.4: dynamic table insert + eviction\n", .{});

    // Capacity for two 38-byte entries.
    var table = DynamicTable{ .capacity = 76 };
    try table.insert("foo", "bar");
    expect(&failures, "first insert -> size 38, count 1", table.size == 38 and table.count == 1);
    expect(&failures, "first insert -> oldest absolute index 0", table.oldestAbsoluteIndex() == 0);

    try table.insert("baz", "qux");
    expect(&failures, "second insert -> size 76, count 2", table.size == 76 and table.count == 2);

    // A third insert evicts the oldest (foo/bar) to make room.
    try table.insert("abc", "def");
    expect(&failures, "third insert evicts oldest -> count 2", table.count == 2);
    expect(&failures, "oldest is now baz/qux (absolute index 1)", std.mem.eql(u8, table.items[0].name, "baz") and table.oldestAbsoluteIndex() == 1);
    expect(&failures, "three total inserts recorded", table.inserts == 3);

    // An entry larger than the whole capacity (30 + 30 + 32 = 92 > 76) is rejected.
    const long_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const long_value = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    expect(&failures, "oversized entry -> QPACK_ENCODER_STREAM_ERROR", table.insert(long_name, long_value) == error.EncoderStreamError);

    // Reducing capacity evicts from the end; capacity 0 clears the table.
    table.setCapacity(38);
    expect(&failures, "reduce capacity to 38 evicts down to one entry", table.count == 1 and table.size == 38);

    table.setCapacity(0);
    expect(&failures, "capacity 0 clears the table", table.count == 0 and table.size == 0);

    std.debug.print("RFC 9204 4.5.1.1: Required Insert Count transform\n", .{});

    // A 100-byte table gives MaxEntries floor(100/32) = 3.
    var sized = DynamicTable{ .capacity = 100 };
    expect(&failures, "MaxEntries for 100-byte table = 3", sized.maxEntries() == 3);

    // RIC 0 always encodes to 0.
    expect(&failures, "encode RIC 0 -> 0", encodeRequiredInsertCount(0, 3) == 0);

    // The RFC worked example: RIC 9 with MaxEntries 3 encodes to 4.
    expect(&failures, "encode RIC 9 (MaxEntries 3) -> 4", encodeRequiredInsertCount(9, 3) == 4);

    // And decodes back to 9 given 10 inserts received.
    expect(&failures, "decode enc 4 (10 inserts, MaxEntries 3) -> RIC 9", (try decodeRequiredInsertCount(4, 10, 3)) == 9);
    expect(&failures, "decode enc 0 -> RIC 0", (try decodeRequiredInsertCount(0, 10, 3)) == 0);

    // An encoded value beyond the full range is unreconstructable.
    expect(&failures, "decode enc 7 (> 2*MaxEntries) -> QPACK_DECOMPRESSION_FAILED", decodeRequiredInsertCount(7, 10, 3) == error.DecompressionFailed);

    std.debug.print("RFC 9204 4.5.1.2: Base resolution\n", .{});

    expect(&failures, "Base sign 0: RIC 9 + delta 0 = 9", resolveBase(9, false, 0) == 9);
    expect(&failures, "Base sign 1: RIC 9 - delta 2 - 1 = 6", resolveBase(9, true, 2) == 6);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9204 P2 dynamic-table + RIC checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
