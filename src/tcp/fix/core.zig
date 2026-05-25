//! zix fix core — parsing, building, checksum, session handler.
//! All functions are pub for test imports.
//! No heap allocation. Zero-copy field parsing (slices into caller buffer).

const std = @import("std");
const Logger = @import("../../logger/logger.zig").Logger;

pub const SOH: u8 = 0x01;
pub const VERSION: []const u8 = "FIX.4.2";
pub const MAX_FIELDS: usize = 64;
pub const MAX_MSG_SIZE: usize = 8192;

pub const Field = struct {
    tag: u16,
    value: []const u8,
};

pub const BuildField = struct {
    tag: u16,
    value: []const u8,
};

// --------------------------------------------------------- //
// Framing
// --------------------------------------------------------- //

/// Scan buf for the end of the first complete FIX message.
///
/// Return:
/// - index one past the final SOH of the tag-10 field
/// - null if no complete message found
pub fn findMessageEnd(buf: []const u8) ?usize {
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 1) {
        if (buf[i] == SOH and buf[i + 1] == '1' and buf[i + 2] == '0' and buf[i + 3] == '=') {
            const value_start = i + 4;
            const end = std.mem.indexOfScalarPos(u8, buf, value_start, SOH) orelse return null;
            return end + 1;
        }
    }
    return null;
}

// --------------------------------------------------------- //
// Parsing
// --------------------------------------------------------- //

/// Parse tag=value fields from a raw FIX message buf.
/// Fields are zero-copy slices into buf. Returns the number of fields parsed.
pub fn parseFields(buf: []const u8, out: []Field) !usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < buf.len) {
        if (count >= out.len) return error.TooManyFields;
        const eq = std.mem.indexOfScalarPos(u8, buf, i, '=') orelse break;
        const soh = std.mem.indexOfScalarPos(u8, buf, eq + 1, SOH) orelse break;
        const tag = std.fmt.parseInt(u16, buf[i..eq], 10) catch return error.BadTag;
        out[count] = .{ .tag = tag, .value = buf[eq + 1 .. soh] };
        count += 1;
        i = soh + 1;
    }
    return count;
}

/// Return the value of the first field with the given tag, or null.
pub fn getField(fields: []const Field, tag: u16) ?[]const u8 {
    for (fields) |f| {
        if (f.tag == tag) return f.value;
    }
    return null;
}

// --------------------------------------------------------- //
// Checksum
// --------------------------------------------------------- //

/// Sum of all bytes in buf, mod 256.
pub fn computeChecksum(buf: []const u8) u8 {
    var sum: u32 = 0;
    for (buf) |b| sum += b;
    return @truncate(sum % 256);
}

/// Verify the tag-10 CheckSum field in a complete raw FIX message.
/// Sum covers all bytes from the start through (and including) the SOH of the
/// last field before tag 10.
pub fn verifyChecksum(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 4 <= raw.len) : (i += 1) {
        if (raw[i] == SOH and raw[i + 1] == '1' and raw[i + 2] == '0' and raw[i + 3] == '=') {
            const cs = computeChecksum(raw[0 .. i + 1]);
            const value_start = i + 4;
            const soh = std.mem.indexOfScalarPos(u8, raw, value_start, SOH) orelse return false;
            const cs_value = std.fmt.parseInt(u8, raw[value_start..soh], 10) catch return false;
            return cs == cs_value;
        }
    }
    return false;
}

// --------------------------------------------------------- //
// Building
// --------------------------------------------------------- //

/// Build a complete FIX 4.2 message into out.
///
/// Param:
/// sender - []const u8 (our SenderCompID)
/// target - []const u8 (peer TargetCompID)
/// seq - u32 (outbound sequence)
/// msgtype - []const u8 (tag-35 value)
/// extra - []const BuildField (additional body fields after the standard header)
///
/// Return:
/// - number of bytes written
pub fn buildMessage(
    out: []u8,
    sender: []const u8,
    target: []const u8,
    seq: u32,
    msgtype: []const u8,
    extra: []const BuildField,
) !usize {
    var body: [MAX_MSG_SIZE]u8 = undefined;
    var bp: usize = 0;

    bp += (try std.fmt.bufPrint(body[bp..], "35={s}\x01", .{msgtype})).len;
    bp += (try std.fmt.bufPrint(body[bp..], "49={s}\x01", .{sender})).len;
    bp += (try std.fmt.bufPrint(body[bp..], "56={s}\x01", .{target})).len;
    bp += (try std.fmt.bufPrint(body[bp..], "34={d}\x01", .{seq})).len;
    bp += (try std.fmt.bufPrint(body[bp..], "52=20260520-00:00:00\x01", .{})).len;
    for (extra) |f| {
        bp += (try std.fmt.bufPrint(body[bp..], "{d}={s}\x01", .{ f.tag, f.value })).len;
    }

    var pos: usize = 0;
    pos += (try std.fmt.bufPrint(out[pos..], "8={s}\x01", .{VERSION})).len;
    pos += (try std.fmt.bufPrint(out[pos..], "9={d}\x01", .{bp})).len;
    if (pos + bp > out.len) return error.NoSpaceLeft;
    @memcpy(out[pos..][0..bp], body[0..bp]);
    pos += bp;

    const cs = computeChecksum(out[0..pos]);
    pos += (try std.fmt.bufPrint(out[pos..], "10={d:0>3}\x01", .{cs})).len;

    return pos;
}

// --------------------------------------------------------- //
// Session handler
// --------------------------------------------------------- //

/// Serve one FIX connection: Logon handshake, echo loop, Logout.
/// Closes the stream before returning.
///
/// Param:
/// comp_id - []const u8 (the server's SenderCompID)
/// logger - ?*Logger (optional. when non-null, session() is called after each message processed)
pub fn serveConn(stream: std.Io.net.Stream, io: std.Io, comp_id: []const u8, logger: ?*Logger) !void {
    defer stream.close(io);
    var rd_buf: [MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    var recv_buf: [MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;

    var seq_out: u32 = 1;
    var peer_comp_id: [64]u8 = undefined;
    var peer_len: usize = 0;

    outer: while (true) {
        const msg_end = while (true) {
            if (findMessageEnd(recv_buf[0..recv_len])) |end| break end;
            if (recv_len >= recv_buf.len) return error.MessageTooLarge;
            const b = rd.interface.takeByte() catch return;
            recv_buf[recv_len] = b;
            recv_len += 1;
        };

        const raw = recv_buf[0..msg_end];

        var fields: [MAX_FIELDS]Field = undefined;
        const nf = parseFields(raw, &fields) catch return;
        const fslice = fields[0..nf];

        if (!verifyChecksum(raw)) return;

        const msgtype = getField(fslice, 35) orelse return;
        const sender = getField(fslice, 49) orelse "";

        const remaining = recv_len - msg_end;
        if (remaining > 0) {
            std.mem.copyForwards(u8, recv_buf[0..remaining], recv_buf[msg_end..recv_len]);
        }
        recv_len = remaining;

        var out_buf: [MAX_MSG_SIZE]u8 = undefined;

        const seq_in = std.fmt.parseInt(u64, getField(fslice, 34) orelse "0", 10) catch 0;

        if (std.mem.eql(u8, msgtype, "A")) {
            @memcpy(peer_comp_id[0..sender.len], sender);
            peer_len = sender.len;
            const hb_int = getField(fslice, 108) orelse "30";
            const extra = [_]BuildField{
                .{ .tag = 98, .value = "0" },
                .{ .tag = 108, .value = hb_int },
            };
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "A", &extra);
            seq_out += 1;
            try wr.interface.writeAll(out_buf[0..n]);
            try wr.interface.flush();
            if (logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "Logon");
        } else if (std.mem.eql(u8, msgtype, "5")) {
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "5", &.{});
            seq_out += 1;
            try wr.interface.writeAll(out_buf[0..n]);
            try wr.interface.flush();
            if (logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "Logout");
            break :outer;
        } else if (std.mem.eql(u8, msgtype, "0")) {
            var extra_buf: [1]BuildField = undefined;
            var extra_len: usize = 0;
            if (getField(fslice, 112)) |tr| {
                extra_buf[0] = .{ .tag = 112, .value = tr };
                extra_len = 1;
            }
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "0", extra_buf[0..extra_len]);
            seq_out += 1;
            try wr.interface.writeAll(out_buf[0..n]);
            try wr.interface.flush();
            if (logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "Heartbeat");
        } else if (std.mem.eql(u8, msgtype, "1")) {
            const tr = getField(fslice, 112) orelse "0";
            const extra = [_]BuildField{.{ .tag = 112, .value = tr }};
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "0", &extra);
            seq_out += 1;
            try wr.interface.writeAll(out_buf[0..n]);
            try wr.interface.flush();
            if (logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "TestRequest");
        } else {
            var body_fields: [MAX_FIELDS]BuildField = undefined;
            var body_count: usize = 0;
            for (fslice) |f| {
                switch (f.tag) {
                    8, 9, 35, 49, 56, 34, 52, 10 => {},
                    else => {
                        if (body_count < body_fields.len) {
                            body_fields[body_count] = .{ .tag = f.tag, .value = f.value };
                            body_count += 1;
                        }
                    },
                }
            }
            const n = try buildMessage(
                &out_buf,
                comp_id,
                peer_comp_id[0..peer_len],
                seq_out,
                msgtype,
                body_fields[0..body_count],
            );
            seq_out += 1;
            try wr.interface.writeAll(out_buf[0..n]);
            try wr.interface.flush();
            if (logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "msg");
        }
    }
}

// --------------------------------------------------------- //
// Unit tests
// --------------------------------------------------------- //

test "zix fix: findMessageEnd returns null for empty buf" {
    try std.testing.expect(findMessageEnd("") == null);
}

test "zix fix: findMessageEnd returns null when tag 10 absent" {
    const buf = "8=FIX.4.2\x019=5\x0135=A\x01";
    try std.testing.expect(findMessageEnd(buf) == null);
}

test "zix fix: findMessageEnd finds end of a complete message" {
    const buf = "8=FIX.4.2\x019=5\x0135=A\x0110=123\x01";
    const end = findMessageEnd(buf);
    try std.testing.expect(end != null);
    try std.testing.expectEqual(buf.len, end.?);
}

test "zix fix: findMessageEnd stops at first message when two are present" {
    const msg1 = "8=FIX.4.2\x019=5\x0135=A\x0110=001\x01";
    const msg2 = "8=FIX.4.2\x019=5\x0135=5\x0110=002\x01";
    const buf = msg1 ++ msg2;
    const end = findMessageEnd(buf);
    try std.testing.expect(end != null);
    try std.testing.expectEqual(msg1.len, end.?);
}

test "zix fix: parseFields extracts all tag=value pairs" {
    const msg = "8=FIX.4.2\x019=5\x0135=A\x0149=CLIENT\x0156=SERVER\x0134=1\x01";
    var fields: [16]Field = undefined;
    const n = try parseFields(msg, &fields);
    try std.testing.expectEqual(6, n);
    try std.testing.expectEqual(8, fields[0].tag);
    try std.testing.expectEqualStrings("FIX.4.2", fields[0].value);
    try std.testing.expectEqual(35, fields[2].tag);
    try std.testing.expectEqualStrings("A", fields[2].value);
    try std.testing.expectEqual(56, fields[4].tag);
    try std.testing.expectEqualStrings("SERVER", fields[4].value);
}

test "zix fix: parseFields returns error.BadTag on non-numeric tag" {
    const msg = "bad=value\x01";
    var fields: [4]Field = undefined;
    try std.testing.expectError(error.BadTag, parseFields(msg, &fields));
}

test "zix fix: getField finds a tag" {
    const fields = [_]Field{
        .{ .tag = 8, .value = "FIX.4.2" },
        .{ .tag = 35, .value = "D" },
        .{ .tag = 49, .value = "CLIENT" },
    };
    try std.testing.expectEqualStrings("D", getField(&fields, 35).?);
    try std.testing.expectEqualStrings("CLIENT", getField(&fields, 49).?);
}

test "zix fix: getField returns null for absent tag" {
    const fields = [_]Field{.{ .tag = 8, .value = "FIX.4.2" }};
    try std.testing.expect(getField(&fields, 35) == null);
}

test "zix fix: computeChecksum of empty buf is 0" {
    try std.testing.expectEqual(0, computeChecksum(""));
}

test "zix fix: computeChecksum wraps at 256" {
    const buf = [_]u8{0x01} ** 256;
    try std.testing.expectEqual(0, computeChecksum(&buf));
}

test "zix fix: computeChecksum known value" {
    const buf = "8=FIX.4.2\x01";
    try std.testing.expectEqual(31, computeChecksum(buf));
}

test "zix fix: buildMessage produces a verifiable checksum" {
    var out: [MAX_MSG_SIZE]u8 = undefined;
    const n = try buildMessage(&out, "SERVER", "CLIENT", 1, "A", &.{
        .{ .tag = 98, .value = "0" },
        .{ .tag = 108, .value = "30" },
    });
    try std.testing.expect(verifyChecksum(out[0..n]));
}

test "zix fix: buildMessage parses back with correct MsgType and CompIDs" {
    var out: [MAX_MSG_SIZE]u8 = undefined;
    const n = try buildMessage(&out, "SRV", "CLT", 5, "D", &.{
        .{ .tag = 11, .value = "ORD001" },
        .{ .tag = 55, .value = "AAPL" },
    });
    var fields: [MAX_FIELDS]Field = undefined;
    const nf = try parseFields(out[0..n], &fields);
    const fslice = fields[0..nf];

    try std.testing.expectEqualStrings("D", getField(fslice, 35).?);
    try std.testing.expectEqualStrings("SRV", getField(fslice, 49).?);
    try std.testing.expectEqualStrings("CLT", getField(fslice, 56).?);
    try std.testing.expectEqualStrings("5", getField(fslice, 34).?);
    try std.testing.expectEqualStrings("ORD001", getField(fslice, 11).?);
    try std.testing.expectEqualStrings("AAPL", getField(fslice, 55).?);
}

test "zix fix: verifyChecksum returns false for tampered byte" {
    var out: [MAX_MSG_SIZE]u8 = undefined;
    const n = try buildMessage(&out, "S", "C", 1, "0", &.{});
    out[5] ^= 0xFF;
    try std.testing.expect(!verifyChecksum(out[0..n]));
}

test "zix fix: bodyLength field equals byte count from tag 35 to last SOH before tag 10" {
    var out: [MAX_MSG_SIZE]u8 = undefined;
    const n = try buildMessage(&out, "SRV", "CLT", 1, "A", &.{
        .{ .tag = 98, .value = "0" },
    });
    const raw = out[0..n];

    var fields: [MAX_FIELDS]Field = undefined;
    const nf = try parseFields(raw, &fields);
    const bl_str = getField(fields[0..nf], 9).?;
    const bl = try std.fmt.parseInt(usize, bl_str, 10);

    const tag35_start = std.mem.indexOf(u8, raw, "35=").?;

    var i: usize = 0;
    var tag10_soh: usize = 0;
    while (i + 4 <= raw.len) : (i += 1) {
        if (raw[i] == SOH and raw[i + 1] == '1' and raw[i + 2] == '0' and raw[i + 3] == '=') {
            tag10_soh = i + 1;
            break;
        }
    }
    const measured = tag10_soh - tag35_start;
    try std.testing.expectEqual(bl, measured);
}
