//! FIX 4.x PoC core — parsing, building, checksum, session handler.
//! All functions are pub for test imports.
//! No heap allocation. Zero-copy field parsing (slices into caller buffer).
//! Self-contained: no imports from zix src.

const std = @import("std");

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

// ------------------------------------------------------------------- //
// Framing                                                              //
// ------------------------------------------------------------------- //

/// Scan buf for the end of the first complete FIX message.
///
/// Return:
/// - ?usize (index one past the final SOH of the tag-10 field, or null)
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

// ------------------------------------------------------------------- //
// Parsing                                                              //
// ------------------------------------------------------------------- //

/// Parse tag=value fields from a raw FIX message buf.
/// Fields are zero-copy slices into buf.
///
/// Return:
/// - !usize (number of fields parsed)
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

// ------------------------------------------------------------------- //
// Checksum                                                             //
// ------------------------------------------------------------------- //

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

// ------------------------------------------------------------------- //
// Building                                                             //
// ------------------------------------------------------------------- //

/// Build a complete FIX 4.2 message into out.
/// sender: our SenderCompID. target: peer TargetCompID. seq: outbound sequence.
/// msgtype: tag-35 value. extra: additional body fields after the standard header.
///
/// Return:
/// - !usize (number of bytes written)
pub fn buildMessage(
    out: []u8,
    sender: []const u8,
    target: []const u8,
    seq: u32,
    msgtype: []const u8,
    extra: []const BuildField,
) !usize {
    // Build body (tag 35 onward) into a temporary buffer to measure BodyLength.
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

    // Write the full message: BeginString + BodyLength + body + CheckSum.
    var pos: usize = 0;
    pos += (try std.fmt.bufPrint(out[pos..], "8={s}\x01", .{VERSION})).len;
    pos += (try std.fmt.bufPrint(out[pos..], "9={d}\x01", .{bp})).len;
    if (pos + bp > out.len) return error.NoSpaceLeft;
    @memcpy(out[pos..][0..bp], body[0..bp]);
    pos += bp;

    // Checksum covers everything from byte 0 through the SOH of the last body field.
    const cs = computeChecksum(out[0..pos]);
    pos += (try std.fmt.bufPrint(out[pos..], "10={d:0>3}\x01", .{cs})).len;

    return pos;
}

// ------------------------------------------------------------------- //
// Session handler                                                      //
// ------------------------------------------------------------------- //

/// Serve one FIX connection: Logon handshake, echo loop, Logout.
/// comp_id: the server's SenderCompID.
pub fn serveConn(stream: std.Io.net.Stream, io: std.Io, comp_id: []const u8) !void {
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
        // Accumulate bytes one at a time until a complete FIX message is found.
        // readSliceShort with a large buffer blocks on live TCP connections (it loops
        // until the buffer is full or EOF). takeByte reads one byte and returns,
        // with the reader's internal buffer absorbing the rest of the TCP segment.
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

        if (!verifyChecksum(raw)) {
            std.debug.print("fix: bad checksum — closing\n", .{});
            return;
        }

        const msgtype = getField(fslice, 35) orelse return;
        const sender = getField(fslice, 49) orelse "";

        std.debug.print("fix: recv 35={s} from {s}\n", .{ msgtype, sender });

        // Shift unconsumed bytes to front of recv_buf.
        const remaining = recv_len - msg_end;
        if (remaining > 0) {
            std.mem.copyForwards(u8, recv_buf[0..remaining], recv_buf[msg_end..recv_len]);
        }
        recv_len = remaining;

        var out_buf: [MAX_MSG_SIZE]u8 = undefined;

        if (std.mem.eql(u8, msgtype, "A")) {
            // Logon: record peer CompID, respond with Logon.
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
            std.debug.print("fix: sent Logon\n", .{});
        } else if (std.mem.eql(u8, msgtype, "5")) {
            // Logout: respond and close.
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "5", &.{});
            seq_out += 1;
            try wr.interface.writeAll(out_buf[0..n]);
            try wr.interface.flush();
            std.debug.print("fix: sent Logout\n", .{});
            break :outer;
        } else if (std.mem.eql(u8, msgtype, "0")) {
            // Heartbeat: echo back (with TestReqID if present).
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
        } else if (std.mem.eql(u8, msgtype, "1")) {
            // TestRequest: respond with Heartbeat + TestReqID.
            const tr = getField(fslice, 112) orelse "0";
            const extra = [_]BuildField{.{ .tag = 112, .value = tr }};
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, "0", &extra);
            seq_out += 1;
            try wr.interface.writeAll(out_buf[0..n]);
            try wr.interface.flush();
        } else {
            // Application message: collect body fields and echo.
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
            std.debug.print("fix: echoed 35={s}\n", .{msgtype});
        }
    }
}
