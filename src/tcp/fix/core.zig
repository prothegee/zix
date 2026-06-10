//! zix fix core: parsing, building, checksum, session handler.
//! All functions are pub for test imports.
//! No heap allocation. Zero-copy field parsing (slices into caller buffer).

const std = @import("std");
const Logger = @import("../../logger/logger.zig").Logger;

pub const SOH: u8 = 0x01;
pub const VERSION: []const u8 = "FIX.4.2";
pub const MAX_FIELDS: usize = 64;
pub const MAX_MSG_SIZE: usize = 8192;
pub const CHECKSUM_MODULUS: u32 = 256;

// --------------------------------------------------------- //

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

/// FIX MsgType (tag 35) string constants: FIX 4.0 through 4.4.
/// Use these instead of raw string literals in route tables and sendMessage calls.
pub const MsgType = struct {
    // Session (handled internally by serveConn, do not route these)
    pub const Heartbeat: []const u8 = "0";
    pub const TestRequest: []const u8 = "1";
    pub const ResendRequest: []const u8 = "2";
    pub const Reject: []const u8 = "3";
    pub const SequenceReset: []const u8 = "4";
    pub const Logout: []const u8 = "5";
    pub const Logon: []const u8 = "A";

    // --------------------------------------------------------- //

    // Application: FIX 4.0 / 4.1
    pub const IOI: []const u8 = "C";
    pub const NewOrderSingle: []const u8 = "D";
    pub const NewOrderList: []const u8 = "E";
    pub const OrderCancelRequest: []const u8 = "F";
    pub const OrderCancelReplaceRequest: []const u8 = "G";
    pub const OrderStatusRequest: []const u8 = "H";
    pub const Allocation: []const u8 = "J";
    pub const ListCancelRequest: []const u8 = "K";
    pub const ListExecute: []const u8 = "L";
    pub const ListStatusRequest: []const u8 = "M";
    pub const ListStatus: []const u8 = "N";
    pub const AllocationACK: []const u8 = "P";
    pub const Quote: []const u8 = "S";
    pub const IOIAcknowledgement: []const u8 = "6";
    pub const ExecutionReport: []const u8 = "8";
    pub const OrderCancelReject: []const u8 = "9";

    // --------------------------------------------------------- //

    // Application: FIX 4.2
    pub const QuoteRequest: []const u8 = "R";
    pub const SettlementInstructions: []const u8 = "T";
    pub const MarketDataRequest: []const u8 = "V";
    pub const MarketDataSnapshot: []const u8 = "W";
    pub const MarketDataIncremental: []const u8 = "X";
    pub const MarketDataRequestReject: []const u8 = "Y";
    pub const BusinessMessageReject: []const u8 = "j";

    // --------------------------------------------------------- //

    // Application: FIX 4.3
    pub const QuoteCancel: []const u8 = "Z";
    pub const QuoteStatusRequest: []const u8 = "a";
    pub const MassQuoteAcknowledgement: []const u8 = "b";
    pub const SecurityDefinitionRequest: []const u8 = "c";
    pub const SecurityDefinition: []const u8 = "d";
    pub const SecurityStatusRequest: []const u8 = "e";
    pub const SecurityStatus: []const u8 = "f";
    pub const TradingSessionStatusRequest: []const u8 = "g";
    pub const TradingSessionStatus: []const u8 = "h";
    pub const MassQuote: []const u8 = "i";

    // --------------------------------------------------------- //

    // Application: FIX 4.4 (two-character types)
    pub const TradeCaptureReport: []const u8 = "AE";
    pub const OrderMassStatusRequest: []const u8 = "AF";
    pub const QuoteRequestReject: []const u8 = "AG";
    pub const RFQRequest: []const u8 = "AH";
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

/// Parse tag=value fields from a raw FIX message buf.
/// Fields are zero-copy slices into buf.
///
/// Return:
/// - !usize (number of fields parsed)
/// - error.TooManyFields if out is too small
/// - error.BadTag if a tag cannot be parsed as u16
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

/// Sum of all bytes in buf, mod 256.
pub fn computeChecksum(buf: []const u8) u8 {
    var sum: u32 = 0;
    for (buf) |b| sum += b;
    return @truncate(sum % CHECKSUM_MODULUS);
}

/// Verify the tag-10 CheckSum field in a complete raw FIX message.
/// Sum covers all bytes from the start through (and including) the SOH of the
/// last field before tag 10.
pub fn verifyChecksum(raw: []const u8) bool {
    var i: usize = 0;
    while (i + 4 <= raw.len) : (i += 1) {
        if (raw[i] == SOH and raw[i + 1] == '1' and raw[i + 2] == '0' and raw[i + 3] == '=') {
            const checksum = computeChecksum(raw[0 .. i + 1]);
            const value_start = i + 4;
            const soh = std.mem.indexOfScalarPos(u8, raw, value_start, SOH) orelse return false;
            const checksum_value = std.fmt.parseInt(u8, raw[value_start..soh], 10) catch return false;
            return checksum == checksum_value;
        }
    }
    return false;
}

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

    const checksum = computeChecksum(out[0..pos]);
    pos += (try std.fmt.bufPrint(out[pos..], "10={d:0>3}\x01", .{checksum})).len;

    return pos;
}

/// Return the current wall-clock time in nanoseconds (Unix epoch basis).
pub fn wallClockNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// --------------------------------------------------------- //

/// Handler function type for routed application messages.
///
/// Param:
/// fields - []const Field (all parsed fields from the received FIX message)
/// ctx - *FixContext (per-connection context: sendMessage, isExpired, deadline_ns)
pub const HandlerFn = *const fn (fields: []const Field, ctx: *FixContext) void;

/// A route entry mapping a FIX MsgType (tag 35) to a handler function.
pub const FixRoute = struct {
    /// MsgType value (tag 35) to match (e.g. "D" for NewOrderSingle).
    msg_type: []const u8,
    /// Handler invoked when a message with this MsgType arrives.
    handler: HandlerFn,
    /// Per-route handler timeout in milliseconds. 0 = use server default (handler_timeout_ms).
    timeout_ms: u32 = 0,
};

/// Per-connection context passed to each routed handler.
pub const FixContext = struct {
    /// SenderCompID of the peer (from their Logon message, tag 49).
    sender_comp_id: []const u8,
    /// Our own SenderCompID (the server comp_id from config, tag 56 in their message).
    target_comp_id: []const u8,
    /// Absolute deadline in nanoseconds (wall clock). Null = no deadline.
    /// Set at dispatch from the tighter of Route.timeout_ms and config handler_timeout_ms.
    /// Handler may read and overwrite.
    deadline_ns: ?u64 = null,
    _fd: std.posix.fd_t,
    _seq_out: *u32,

    /// Build and send a FIX message to the peer.
    ///
    /// Param:
    /// msg_type - []const u8 (tag-35 value, e.g. "8" for ExecutionReport)
    /// extra - []const BuildField (additional body fields after the standard header)
    pub fn sendMessage(self: *FixContext, msg_type: []const u8, extra: []const BuildField) void {
        var out_buf: [MAX_MSG_SIZE]u8 = undefined;
        const n = buildMessage(&out_buf, self.target_comp_id, self.sender_comp_id, self._seq_out.*, msg_type, extra) catch return;
        self._seq_out.* += 1;
        var sent: usize = 0;
        while (sent < n) {
            const rc = std.posix.system.write(self._fd, out_buf[sent..n].ptr, n - sent);
            const written: isize = @bitCast(rc);
            if (written <= 0) return;
            sent += @intCast(written);
        }
    }

    /// Return true if deadline_ns is set and the current wall clock has passed it.
    pub fn isExpired(self: *const FixContext) bool {
        const deadline = self.deadline_ns orelse return false;
        return wallClockNs() >= deadline;
    }
};

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
    /// Idle connection timeout in milliseconds. 0 = disabled.
    /// When non-zero and heartbeat_timeout_ms is 0: connection is closed if no message arrives
    /// within this interval (no TestRequest is sent before closing).
    connection_timeout_ms: u32 = 0,
    /// Server-wide default handler processing timeout in milliseconds. 0 = disabled.
    /// Applied to each routed message dispatch. Per-route FixRoute.timeout_ms overrides this.
    handler_timeout_ms: u32 = 0,
    /// Application message routes. Empty slice = echo all non-session messages (backward compat).
    routes: []const FixRoute = &.{},
};

/// Serve one FIX connection: Logon handshake, route/echo loop, Logout.
/// Closes the stream before returning.
///
/// Param:
/// comp_id - []const u8 (the server's SenderCompID)
/// opts - FixServeOpts (logger, timeouts, and optional application routes)
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
                            const n = buildMessage(&hb_out, comp_id, peer_comp_id[0..peer_len], seq_out, MsgType.Logout, &.{}) catch break :outer;
                            seq_out += 1;
                            writer.interface.writeAll(hb_out[0..n]) catch {};
                            writer.interface.flush() catch {};
                        } else {
                            sent_test_request = true;
                            var test_req_id_buf: [16]u8 = undefined;
                            const test_req_id = std.fmt.bufPrint(&test_req_id_buf, "{d}", .{seq_out}) catch "1";
                            const extra = [_]BuildField{.{ .tag = .TestReqID, .value = test_req_id }};
                            const n = buildMessage(&hb_out, comp_id, peer_comp_id[0..peer_len], seq_out, MsgType.TestRequest, &extra) catch break :outer;
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
        } else if (opts.connection_timeout_ms > 0) conn_to: {
            const timeout_ms: i32 = @intCast(@min(opts.connection_timeout_ms, @as(u32, std.math.maxInt(i32))));
            while (true) {
                if (findMessageEnd(recv_buf[0..recv_len])) |end| break :conn_to end;
                if (recv_len >= recv_buf.len) return error.MessageTooLarge;
                var poll_fd = [1]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const nready = std.posix.poll(&poll_fd, timeout_ms) catch break :outer;
                if (nready == 0) break :outer;
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
        const field_count = parseFields(raw, &fields) catch return;
        const fslice = fields[0..field_count];

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

        if (std.mem.eql(u8, msgtype, MsgType.Logon)) {
            @memcpy(peer_comp_id[0..sender.len], sender);
            peer_len = sender.len;
            const hb_int = getField(fslice, .HeartBtInt) orelse "30";
            const extra = [_]BuildField{
                .{ .tag = .EncryptMethod, .value = "0" },
                .{ .tag = .HeartBtInt, .value = hb_int },
            };
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, MsgType.Logon, &extra);
            seq_out += 1;
            try writer.interface.writeAll(out_buf[0..n]);
            try writer.interface.flush();
            if (opts.logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "Logon");
        } else if (std.mem.eql(u8, msgtype, MsgType.Logout)) {
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, MsgType.Logout, &.{});
            seq_out += 1;
            try writer.interface.writeAll(out_buf[0..n]);
            try writer.interface.flush();
            if (opts.logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "Logout");
            break :outer;
        } else if (std.mem.eql(u8, msgtype, MsgType.Heartbeat)) {
            var extra_buf: [1]BuildField = undefined;
            var extra_len: usize = 0;
            if (getField(fslice, .TestReqID)) |test_req_id| {
                extra_buf[0] = .{ .tag = .TestReqID, .value = test_req_id };
                extra_len = 1;
            }
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, MsgType.Heartbeat, extra_buf[0..extra_len]);
            seq_out += 1;
            try writer.interface.writeAll(out_buf[0..n]);
            try writer.interface.flush();
            if (opts.logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "Heartbeat");
        } else if (std.mem.eql(u8, msgtype, MsgType.TestRequest)) {
            const test_req_id = getField(fslice, .TestReqID) orelse "0";
            const extra = [_]BuildField{.{ .tag = .TestReqID, .value = test_req_id }};
            const n = try buildMessage(&out_buf, comp_id, peer_comp_id[0..peer_len], seq_out, MsgType.Heartbeat, &extra);
            seq_out += 1;
            try writer.interface.writeAll(out_buf[0..n]);
            try writer.interface.flush();
            if (opts.logger) |lg| lg.session(msgtype, sender, comp_id, seq_in, "TestRequest");
        } else if (opts.routes.len > 0 and peer_len > 0) {
            for (opts.routes) |route| {
                if (std.mem.eql(u8, msgtype, route.msg_type)) {
                    const effective_ms = blk: {
                        const a = route.timeout_ms;
                        const b = opts.handler_timeout_ms;
                        break :blk if (a > 0 and b > 0) @min(a, b) else if (a > 0) a else b;
                    };
                    var ctx = FixContext{
                        .sender_comp_id = peer_comp_id[0..peer_len],
                        .target_comp_id = comp_id,
                        .deadline_ns = if (effective_ms > 0)
                            wallClockNs() + @as(u64, effective_ms) * std.time.ns_per_ms
                        else
                            null,
                        ._fd = fd,
                        ._seq_out = &seq_out,
                    };
                    route.handler(fslice, &ctx);
                    if (opts.logger) |lg| lg.session(msgtype, peer_comp_id[0..peer_len], comp_id, seq_in, "dispatch");
                    break;
                }
            }
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
    const field_count = try parseFields(out[0..n], &fields);
    const fslice = fields[0..field_count];

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
    const field_count = try parseFields(raw, &fields);
    const body_len_str = getField(fields[0..field_count], .BodyLength).?;
    const body_len = try std.fmt.parseInt(usize, body_len_str, 10);

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
    try std.testing.expectEqual(body_len, measured);
}

test "zix fix: MsgType session constants match FIX 4.x spec" {
    try std.testing.expectEqualStrings("0", MsgType.Heartbeat);
    try std.testing.expectEqualStrings("1", MsgType.TestRequest);
    try std.testing.expectEqualStrings("2", MsgType.ResendRequest);
    try std.testing.expectEqualStrings("3", MsgType.Reject);
    try std.testing.expectEqualStrings("4", MsgType.SequenceReset);
    try std.testing.expectEqualStrings("5", MsgType.Logout);
    try std.testing.expectEqualStrings("A", MsgType.Logon);
}

test "zix fix: MsgType application single-char constants" {
    try std.testing.expectEqualStrings("8", MsgType.ExecutionReport);
    try std.testing.expectEqualStrings("9", MsgType.OrderCancelReject);
    try std.testing.expectEqualStrings("D", MsgType.NewOrderSingle);
    try std.testing.expectEqualStrings("F", MsgType.OrderCancelRequest);
    try std.testing.expectEqualStrings("G", MsgType.OrderCancelReplaceRequest);
    try std.testing.expectEqualStrings("V", MsgType.MarketDataRequest);
    try std.testing.expectEqualStrings("W", MsgType.MarketDataSnapshot);
    try std.testing.expectEqualStrings("X", MsgType.MarketDataIncremental);
    try std.testing.expectEqualStrings("j", MsgType.BusinessMessageReject);
}

test "zix fix: MsgType application two-char constants" {
    try std.testing.expectEqualStrings("AE", MsgType.TradeCaptureReport);
    try std.testing.expectEqualStrings("AF", MsgType.OrderMassStatusRequest);
    try std.testing.expectEqualStrings("AG", MsgType.QuoteRequestReject);
    try std.testing.expectEqualStrings("AH", MsgType.RFQRequest);
}
