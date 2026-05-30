//! zix fix core — parsing, building, checksum, session handler.
//! All functions are pub for test imports.
//! No heap allocation. Zero-copy field parsing (slices into caller buffer).

const std = @import("std");
const Logger = @import("../../logger/logger.zig").Logger;

pub const SOH: u8 = 0x01;
pub const VERSION: []const u8 = "FIX.4.2";
pub const MAX_FIELDS: usize = 64;
pub const MAX_MSG_SIZE: usize = 8192;

/// FIX 4.x standard tag numbers (nonexhaustive).
/// Use @enumFromInt for custom or extension tags not listed here.
pub const Tag = enum(u16) {
    Account = 1,
    AvgPx = 6,
    BeginString = 8,
    BodyLength = 9,
    CheckSum = 10,
    ClOrdID = 11,
    CumQty = 14,
    Currency = 15,
    ExecID = 17,
    ExecTransType = 20,
    HandlInst = 21,
    SecurityIDSource = 22,
    LastPx = 31,
    LastShares = 32,
    MsgSeqNum = 34,
    MsgType = 35,
    OrderID = 37,
    OrderQty = 38,
    OrdStatus = 39,
    OrdType = 40,
    OrigClOrdID = 41,
    PossDupFlag = 43,
    Price = 44,
    SecurityID = 48,
    SenderCompID = 49,
    SenderSubID = 50,
    SendingTime = 52,
    Side = 54,
    Symbol = 55,
    TargetCompID = 56,
    TargetSubID = 57,
    Text = 58,
    TimeInForce = 59,
    TransactTime = 60,
    TradeDate = 75,
    PossResend = 97,
    EncryptMethod = 98,
    StopPx = 99,
    ExDestination = 100,
    HeartBtInt = 108,
    TestReqID = 112,
    OrigSendingTime = 122,
    GapFillFlag = 123,
    NoRelatedSym = 146,
    ExecType = 150,
    LeavesQty = 151,
    SecurityType = 167,
    MaturityMonthYear = 200,
    SecurityExchange = 207,
    NoMDEntries = 268,
    LastMsgSeqNumProcessed = 369,
    NoPartyIDs = 453,
    NoUnderlyings = 539,
    NoLegs = 555,
    _,
};

pub const Field = struct {
    tag: Tag,
    value: []const u8,
};

pub const BuildField = struct {
    tag: Tag,
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
        const tag_num = std.fmt.parseInt(u16, buf[i..eq], 10) catch return error.BadTag;
        out[count] = .{ .tag = @enumFromInt(tag_num), .value = buf[eq + 1 .. soh] };
        count += 1;
        i = soh + 1;
    }
    return count;
}

/// Return the value of the first field with the given tag, or null.
pub fn getField(fields: []const Field, tag: Tag) ?[]const u8 {
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
        bp += (try std.fmt.bufPrint(body[bp..], "{d}={s}\x01", .{ @intFromEnum(f.tag), f.value })).len;
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

/// Options for serveConn.
pub const FixServeOpts = struct {
    /// Optional logger. When non-null, session() is called after each message processed.
    logger: ?*Logger = null,
    /// Heartbeat timeout in milliseconds. 0 = disabled.
    /// When non-zero: after this interval with no incoming message, a TestRequest (35=1) is sent.
    /// If no response arrives within another interval, a Logout (35=5) is sent and the connection closes.
    /// Note: applies only after Logon completes (peer CompID known). Before Logon, timeout closes silently.
    heartbeat_timeout_ms: u32 = 0,
};

/// Serve one FIX connection: Logon handshake, echo loop, Logout.
/// Closes the stream before returning.
///
/// Param:
/// comp_id - []const u8 (the server's SenderCompID)
/// opts - FixServeOpts (logger and optional heartbeat timeout)
pub fn serveConn(stream: std.Io.net.Stream, io: std.Io, comp_id: []const u8, opts: FixServeOpts) !void {
    defer stream.close(io);
    var rd_buf: [MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [MAX_MSG_SIZE]u8 = undefined;
    var reader = stream.reader(io, &rd_buf);
    var writer = stream.writer(io, &wr_buf);
    const fd = stream.socket.handle;

    var recv_buf: [MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;

    var seq_out: u32 = 1;
    var peer_comp_id: [64]u8 = undefined;
    var peer_len: usize = 0;
    var sent_test_request: bool = false;

    outer: while (true) {
        const msg_end = if (opts.heartbeat_timeout_ms > 0) hb: {
            const timeout_ms: i32 = @intCast(@min(opts.heartbeat_timeout_ms, @as(u32, std.math.maxInt(i32))));
            while (true) {
                if (findMessageEnd(recv_buf[0..recv_len])) |end| break :hb end;
                if (recv_len >= recv_buf.len) return error.MessageTooLarge;
                var poll_fd = [1]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const nready = std.posix.poll(&poll_fd, timeout_ms) catch break :outer;
                if (nready == 0) {
                    if (peer_len > 0) {
                        var hb_out: [MAX_MSG_SIZE]u8 = undefined;
                        if (sent_test_request) {
                            const n = buildMessage(&hb_out, comp_id, peer_comp_id[0..peer_len], seq_out, "5", &.{}) catch break :outer;
                            seq_out += 1;
                            writer.interface.writeAll(hb_out[0..n]) catch {};
                            writer.interface.flush() catch {};
                        } else {
                            sent_test_request = true;
                            var tr_buf: [16]u8 = undefined;
                            const tr = std.fmt.bufPrint(&tr_buf, "{d}", .{seq_out}) catch "1";
                            const extra = [_]BuildField{.{ .tag = .TestReqID, .value = tr }};
                            const n = buildMessage(&hb_out, comp_id, peer_comp_id[0..peer_len], seq_out, "1", &extra) catch break :outer;
                            seq_out += 1;
                            writer.interface.writeAll(hb_out[0..n]) catch {};
                            writer.interface.flush() catch {};
                            continue;
                        }
                    }
                    break :outer;
                }
                const n = std.posix.read(fd, recv_buf[recv_len..]) catch break :outer;
                if (n == 0) break :outer;
                recv_len += n;
            }
            unreachable;
        } else no_hb: {
            while (true) {
                if (findMessageEnd(recv_buf[0..recv_len])) |end| break :no_hb end;
                if (recv_len >= recv_buf.len) return error.MessageTooLarge;
                const b = reader.interface.takeByte() catch break :outer;
                recv_buf[recv_len] = b;
                recv_len += 1;
            }
            unreachable;
        };

        sent_test_request = false;

        const raw = recv_buf[0..msg_end];

        var fields: [MAX_FIELDS]Field = undefined;
        const nf = parseFields(raw, &fields) catch return;
        const fslice = fields[0..nf];

        if (!verifyChecksum(raw)) return;

        const msgtype = getField(fslice, .MsgType) orelse return;
        const sender = getField(fslice, .SenderCompID) orelse "";

        const remaining = recv_len - msg_end;
        if (remaining > 0) {
            std.mem.copyForwards(u8, recv_buf[0..remaining], recv_buf[msg_end..recv_len]);
        }
        recv_len = remaining;

        var out_buf: [MAX_MSG_SIZE]u8 = undefined;

        const seq_in = std.fmt.parseInt(u64, getField(fslice, .MsgSeqNum) orelse "0", 10) catch 0;

        if (std.mem.eql(u8, msgtype, "A")) {
            @memcpy(peer_comp_id[0..sender.len], sender);
            peer_len = sender.len;
            const hb_int = getField(fslice, .HeartBtInt) orelse "30";
            const extra = [_]BuildField{
                .{ .tag = .EncryptMethod, .value = "0" },
                .{ .tag = .HeartBtInt, .value = hb_int },
            };
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "A", &extra);
            seq_out += 1;
            try writer.interface.writeAll(out_buf[0..n]);
            try writer.interface.flush();
            if (opts.logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "Logon");
        } else if (std.mem.eql(u8, msgtype, "5")) {
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "5", &.{});
            seq_out += 1;
            try writer.interface.writeAll(out_buf[0..n]);
            try writer.interface.flush();
            if (opts.logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "Logout");
            break :outer;
        } else if (std.mem.eql(u8, msgtype, "0")) {
            var extra_buf: [1]BuildField = undefined;
            var extra_len: usize = 0;
            if (getField(fslice, .TestReqID)) |tr| {
                extra_buf[0] = .{ .tag = .TestReqID, .value = tr };
                extra_len = 1;
            }
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "0", extra_buf[0..extra_len]);
            seq_out += 1;
            try writer.interface.writeAll(out_buf[0..n]);
            try writer.interface.flush();
            if (opts.logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "Heartbeat");
        } else if (std.mem.eql(u8, msgtype, "1")) {
            const tr = getField(fslice, .TestReqID) orelse "0";
            const extra = [_]BuildField{.{ .tag = .TestReqID, .value = tr }};
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "0", &extra);
            seq_out += 1;
            try writer.interface.writeAll(out_buf[0..n]);
            try writer.interface.flush();
            if (opts.logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "TestRequest");
        } else {
            var body_fields: [MAX_FIELDS]BuildField = undefined;
            var body_count: usize = 0;
            for (fslice) |f| {
                switch (f.tag) {
                    .BeginString, .BodyLength, .MsgType, .SenderCompID, .TargetCompID, .MsgSeqNum, .SendingTime, .CheckSum => {},
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
            try writer.interface.writeAll(out_buf[0..n]);
            try writer.interface.flush();
            if (opts.logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "msg");
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
    try std.testing.expectEqual(Tag.BeginString, fields[0].tag);
    try std.testing.expectEqualStrings("FIX.4.2", fields[0].value);
    try std.testing.expectEqual(Tag.MsgType, fields[2].tag);
    try std.testing.expectEqualStrings("A", fields[2].value);
    try std.testing.expectEqual(Tag.TargetCompID, fields[4].tag);
    try std.testing.expectEqualStrings("SERVER", fields[4].value);
}

test "zix fix: parseFields returns error.BadTag on non-numeric tag" {
    const msg = "bad=value\x01";
    var fields: [4]Field = undefined;
    try std.testing.expectError(error.BadTag, parseFields(msg, &fields));
}

test "zix fix: getField finds a tag" {
    const fields = [_]Field{
        .{ .tag = .BeginString, .value = "FIX.4.2" },
        .{ .tag = .MsgType, .value = "D" },
        .{ .tag = .SenderCompID, .value = "CLIENT" },
    };
    try std.testing.expectEqualStrings("D", getField(&fields, .MsgType).?);
    try std.testing.expectEqualStrings("CLIENT", getField(&fields, .SenderCompID).?);
}

test "zix fix: getField returns null for absent tag" {
    const fields = [_]Field{.{ .tag = .BeginString, .value = "FIX.4.2" }};
    try std.testing.expect(getField(&fields, .MsgType) == null);
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
        .{ .tag = .EncryptMethod, .value = "0" },
        .{ .tag = .HeartBtInt, .value = "30" },
    });
    try std.testing.expect(verifyChecksum(out[0..n]));
}

test "zix fix: buildMessage parses back with correct MsgType and CompIDs" {
    var out: [MAX_MSG_SIZE]u8 = undefined;
    const n = try buildMessage(&out, "SRV", "CLT", 5, "D", &.{
        .{ .tag = .ClOrdID, .value = "ORD001" },
        .{ .tag = .Symbol, .value = "AAPL" },
    });
    var fields: [MAX_FIELDS]Field = undefined;
    const nf = try parseFields(out[0..n], &fields);
    const fslice = fields[0..nf];

    try std.testing.expectEqualStrings("D", getField(fslice, .MsgType).?);
    try std.testing.expectEqualStrings("SRV", getField(fslice, .SenderCompID).?);
    try std.testing.expectEqualStrings("CLT", getField(fslice, .TargetCompID).?);
    try std.testing.expectEqualStrings("5", getField(fslice, .MsgSeqNum).?);
    try std.testing.expectEqualStrings("ORD001", getField(fslice, .ClOrdID).?);
    try std.testing.expectEqualStrings("AAPL", getField(fslice, .Symbol).?);
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
        .{ .tag = .EncryptMethod, .value = "0" },
    });
    const raw = out[0..n];

    var fields: [MAX_FIELDS]Field = undefined;
    const nf = try parseFields(raw, &fields);
    const bl_str = getField(fields[0..nf], .BodyLength).?;
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
