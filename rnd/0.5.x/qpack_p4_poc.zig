//! QPACK PoC, phase P4 (http3-plan.md): RFC 9204 section 4.5 end-to-end. A field list is encoded
//! with the static-table representations and decoded back, proving the zix encoder and decoder agree.
//!
//! Note:
//! - P1 / P2 / P3 proved each QPACK piece in isolation. P4 is the round trip: take a header list,
//!   encode it (Encoded Field Section Prefix plus one representation per field), decode the bytes,
//!   and confirm the result is byte-identical to the input. This is the self-consistency half of
//!   interop, and it exercises three representations together: Indexed Field Line (4.5.2) for an
//!   exact static match, Literal Field Line with Name Reference (4.5.4) for a static name, and
//!   Literal Field Line with Literal Name (4.5.6) for a field not in the table.
//! - The oracle here is the round trip itself plus the fixed wire bytes the static representations
//!   must produce (e.g. :method GET is the single byte 0xd1). The CROSS-implementation half of P4,
//!   decoding .qif-derived encoded files produced by another QPACK implementation, needs external
//!   fixtures from the qpack-interop test data; that is handled by the verify harness and is PENDING
//!   those fixtures, not faked here.
//! - Static-table, RIC 0 / Base 0 only (no dynamic table), non-Huffman literals. Built on the P1
//!   prefixed-integer codec and static table subset (reproduced so the PoC stays standalone).
//!
//! Run:    zig run rnd/0.5.x/qpack_p4_poc.zig
//! Verify: bash rnd/0.5.x/verify-qpack-p4.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// A decoded prefixed integer (RFC 7541 5.1): the value plus how many bytes it occupied.
const IntResult = struct { value: u64, len: usize };

/// Decode an N-bit prefixed integer (RFC 7541 5.1, reused by QPACK 4.1.1).
fn decodePrefixedInt(data: []const u8, prefix_bits: u4) error{Truncated}!IntResult {
    if (data.len == 0) return error.Truncated;

    const max: u64 = (@as(u64, 1) << prefix_bits) - 1;
    var value: u64 = data[0] & @as(u8, @intCast(max));
    if (value < max) return .{ .value = value, .len = 1 };

    var len: usize = 1;
    var shift: u6 = 0;
    while (true) {
        if (len >= data.len) return error.Truncated;

        const byte = data[len];
        len += 1;
        value += @as(u64, byte & 0x7f) << shift;
        shift += 7;
        if (byte & 0x80 == 0) break;
    }

    return .{ .value = value, .len = len };
}

/// Encode an N-bit prefixed integer (RFC 7541 5.1). `high_bits` are the bits above the prefix in the
/// first byte. Returns bytes written.
fn encodePrefixedInt(out: []u8, prefix_bits: u4, high_bits: u8, value: u64) usize {
    const max: u64 = (@as(u64, 1) << prefix_bits) - 1;
    if (value < max) {
        out[0] = high_bits | @as(u8, @intCast(value));
        return 1;
    }

    out[0] = high_bits | @as(u8, @intCast(max));
    var remaining = value - max;
    var i: usize = 1;
    while (remaining >= 128) {
        out[i] = @as(u8, @intCast(remaining % 128)) + 128;
        remaining /= 128;
        i += 1;
    }
    out[i] = @intCast(remaining);

    return i + 1;
}

// --------------------------------------------------------------- //

/// A field line: a name and value.
const Field = struct { name: []const u8, value: []const u8 };

/// The leading subset of the RFC 9204 Appendix A static table (indices 0..28).
const static_table = [_]Field{
    .{ .name = ":authority", .value = "" },        .{ .name = ":path", .value = "/" },
    .{ .name = "age", .value = "0" },              .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-length", .value = "0" },   .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },              .{ .name = "etag", .value = "" },
    .{ .name = "if-modified-since", .value = "" }, .{ .name = "if-none-match", .value = "" },
    .{ .name = "last-modified", .value = "" },     .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },          .{ .name = "referer", .value = "" },
    .{ .name = "set-cookie", .value = "" },        .{ .name = ":method", .value = "CONNECT" },
    .{ .name = ":method", .value = "DELETE" },     .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "HEAD" },       .{ .name = ":method", .value = "OPTIONS" },
    .{ .name = ":method", .value = "POST" },       .{ .name = ":method", .value = "PUT" },
    .{ .name = ":scheme", .value = "http" },       .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "103" },        .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "304" },        .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "503" },
};

/// Find an exact name + value match in the static table (RFC 9204 4.5.2).
fn staticFindExact(name: []const u8, value: []const u8) ?usize {
    for (static_table, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) return i;
    }

    return null;
}

/// Find the first static-table entry whose name matches (RFC 9204 4.5.4).
fn staticFindName(name: []const u8) ?usize {
    for (static_table, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.name, name)) return i;
    }

    return null;
}

// --------------------------------------------------------------- //

/// Encode a field list into one QPACK field section (RFC 9204 4.5): the RIC 0 / Base 0 prefix
/// followed by one representation per field. Returns total bytes written.
fn encodeFieldList(out: []u8, fields: []const Field) usize {
    var pos: usize = 0;

    // Encoded Field Section Prefix: Required Insert Count 0, Base 0 (static-only).
    pos += encodePrefixedInt(out[pos..], 8, 0x00, 0);
    pos += encodePrefixedInt(out[pos..], 7, 0x00, 0);

    for (fields) |field| {
        if (staticFindExact(field.name, field.value)) |idx| {
            // Indexed Field Line: '1' + T=1 (static) + 6-bit index.
            pos += encodePrefixedInt(out[pos..], 6, 0x80 | 0x40, idx);
        } else if (staticFindName(field.name)) |idx| {
            // Literal Field Line with Name Reference: '01' + N=0 + T=1 + 4-bit index, value literal.
            pos += encodePrefixedInt(out[pos..], 4, 0x40 | 0x10, idx);
            pos += encodePrefixedInt(out[pos..], 7, 0x00, field.value.len);
            @memcpy(out[pos .. pos + field.value.len], field.value);
            pos += field.value.len;
        } else {
            // Literal Field Line with Literal Name: '001' + N=0 + H=0 + 3-bit name length, name,
            // then the value as an 8-bit prefix string literal.
            pos += encodePrefixedInt(out[pos..], 3, 0x20, field.name.len);
            @memcpy(out[pos .. pos + field.name.len], field.name);
            pos += field.name.len;
            pos += encodePrefixedInt(out[pos..], 7, 0x00, field.value.len);
            @memcpy(out[pos .. pos + field.value.len], field.value);
            pos += field.value.len;
        }
    }

    return pos;
}

/// A decoded field list plus how many fields it held.
const DecodedList = struct { fields: [16]Field, len: usize };

/// Decode one QPACK field section (RFC 9204 4.5) into its field list. Static-table, RIC 0 / Base 0,
/// non-Huffman literals only.
fn decodeFieldList(data: []const u8) error{ Truncated, BadRepresentation }!DecodedList {
    var pos: usize = 0;

    // Skip the Encoded Field Section Prefix (RIC + Base), both zero here.
    pos += (decodePrefixedInt(data[pos..], 8) catch return error.Truncated).len;
    pos += (decodePrefixedInt(data[pos..], 7) catch return error.Truncated).len;

    var out: DecodedList = .{ .fields = undefined, .len = 0 };
    while (pos < data.len) {
        const first = data[pos];

        if (first & 0x80 != 0) {
            // Indexed Field Line.
            const idx = decodePrefixedInt(data[pos..], 6) catch return error.Truncated;
            pos += idx.len;
            out.fields[out.len] = static_table[idx.value];
        } else if (first & 0x40 != 0) {
            // Literal Field Line with Name Reference.
            const ni = decodePrefixedInt(data[pos..], 4) catch return error.Truncated;
            pos += ni.len;
            const name = static_table[ni.value].name;

            const vl = decodePrefixedInt(data[pos..], 7) catch return error.Truncated;
            pos += vl.len;
            const value = data[pos .. pos + vl.value];
            pos += vl.value;

            out.fields[out.len] = .{ .name = name, .value = value };
        } else if (first & 0x20 != 0) {
            // Literal Field Line with Literal Name.
            const nl = decodePrefixedInt(data[pos..], 3) catch return error.Truncated;
            pos += nl.len;
            const name = data[pos .. pos + nl.value];
            pos += nl.value;

            const vl = decodePrefixedInt(data[pos..], 7) catch return error.Truncated;
            pos += vl.len;
            const value = data[pos .. pos + vl.value];
            pos += vl.value;

            out.fields[out.len] = .{ .name = name, .value = value };
        } else {
            return error.BadRepresentation;
        }

        out.len += 1;
    }

    return out;
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

/// Whether two field lists are byte-identical.
fn listsEqual(a: []const Field, b: []const Field) bool {
    if (a.len != b.len) return false;

    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.value, y.value)) return false;
    }

    return true;
}

pub fn main() !void {
    var failures: usize = 0;

    // A representative request header list: three exact static hits, one static-name literal value,
    // and one field absent from the table.
    const request = [_]Field{
        .{ .name = ":method", .value = "GET" }, // static 17 -> indexed
        .{ .name = ":path", .value = "/" }, // static 1  -> indexed
        .{ .name = ":scheme", .value = "https" }, // static 23 -> indexed
        .{ .name = ":authority", .value = "example.com" }, // static name 0 -> literal name ref
        .{ .name = "x-custom", .value = "hello" }, // absent -> literal literal name
    };

    var buf: [256]u8 = undefined;
    const encoded_len = encodeFieldList(&buf, &request);
    const encoded = buf[0..encoded_len];

    std.debug.print("RFC 9204 4.5: field section prefix + representation selection\n", .{});

    expect(&failures, "field section prefix is RIC 0 / Base 0 (00 00)", encoded[0] == 0x00 and encoded[1] == 0x00);
    expect(&failures, ":method GET encodes to indexed 0xd1", encoded[2] == 0xd1);
    expect(&failures, ":path / encodes to indexed 0xc1", encoded[3] == 0xc1);
    expect(&failures, ":scheme https encodes to indexed 0xd7", encoded[4] == 0xd7);
    expect(&failures, ":authority uses literal name ref (0x50)", encoded[5] == 0x50);

    std.debug.print("RFC 9204 4.5: encode -> decode round trip\n", .{});

    const decoded = try decodeFieldList(encoded);
    expect(&failures, "decoded field count = 5", decoded.len == 5);
    expect(&failures, "round trip is byte-identical to the input", listsEqual(&request, decoded.fields[0..decoded.len]));

    // Spot-check the two literal representations survived intact.
    expect(&failures, ":authority value = example.com", std.mem.eql(u8, decoded.fields[3].value, "example.com"));
    expect(&failures, "x-custom literal name + value", std.mem.eql(u8, decoded.fields[4].name, "x-custom") and std.mem.eql(u8, decoded.fields[4].value, "hello"));

    // A second, response-shaped list round-trips too (status + literal header).
    const response = [_]Field{
        .{ .name = ":status", .value = "200" }, // static 25 -> indexed
        .{ .name = "location", .value = "/home" }, // static name 12 -> literal name ref
    };
    var buf2: [128]u8 = undefined;
    const decoded2 = try decodeFieldList(buf2[0..encodeFieldList(&buf2, &response)]);
    expect(&failures, "response list round-trips", listsEqual(&response, decoded2.fields[0..decoded2.len]));

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9204 P4 round-trip checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
