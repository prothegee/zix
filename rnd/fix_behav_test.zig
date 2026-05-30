//! Behaviour tests: observable FIX session contract.
//! Verifies: Logon response fields, echo body preservation, clean Logout.
//! Run: zig test rnd/fix_behav_test.zig

const std = @import("std");
const core = @import("fix_poc_core.zig");

const TEST_PORT: u16 = 19540;

// ------------------------------------------------------------------- //
// Shared                                                               //
// ------------------------------------------------------------------- //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    core.serveConn(stream, io, "SERVER") catch |e| {
        if (e != error.ConnectionClosed and e != error.BrokenPipe) ctx.err = e;
    };
    stream.close(io);
}

fn setup(io: std.Io, ctx: *ServerCtx, port: u16) !std.Thread {
    ctx.err = null;
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    ctx.listener = try addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    return std.Thread.spawn(.{ .stack_size = 512 * 1024 }, runServer, .{ ctx, io });
}

fn recvMsg(
    rd: *std.Io.Reader,
    recv_buf: []u8,
    recv_len: *usize,
    out_fields: []core.Field,
) !usize {
    while (true) {
        if (core.findMessageEnd(recv_buf[0..recv_len.*])) |end| {
            const raw = recv_buf[0..end];
            const nf = try core.parseFields(raw, out_fields);
            const remaining = recv_len.* - end;
            if (remaining > 0) {
                std.mem.copyForwards(u8, recv_buf[0..remaining], recv_buf[end..recv_len.*]);
            }
            recv_len.* = remaining;
            return nf;
        }
        if (recv_len.* >= recv_buf.len) return error.MessageTooLarge;
        const b = try rd.takeByte();
        recv_buf[recv_len.*] = b;
        recv_len.* += 1;
    }
}

fn sendMsg(
    wr: anytype,
    out_buf: []u8,
    sender: []const u8,
    target: []const u8,
    seq: *u32,
    msgtype: []const u8,
    extra: []const core.BuildField,
) !void {
    const n = try core.buildMessage(out_buf, sender, target, seq.*, msgtype, extra);
    seq.* += 1;
    try wr.interface.writeAll(out_buf[0..n]);
    try wr.interface.flush();
}

// ------------------------------------------------------------------- //
// Tests                                                                //
// ------------------------------------------------------------------- //

test "behav: Logon response has MsgType=A and CompIDs swapped" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT);

    const sa = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT);
    const stream = try sa.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var rd_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);
    var recv_buf: [core.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;
    var out_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var fields: [core.MAX_FIELDS]core.Field = undefined;
    var seq: u32 = 1;

    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "A", &.{
        .{ .tag = 98, .value = "0" }, .{ .tag = 108, .value = "30" },
    });
    const nf = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);
    const fslice = fields[0..nf];

    // MsgType must be Logon.
    try std.testing.expectEqualStrings("A", core.getField(fslice, 35).?);
    // SenderCompID must be the server's ID.
    try std.testing.expectEqualStrings("SERVER", core.getField(fslice, 49).?);
    // TargetCompID must be our ID.
    try std.testing.expectEqualStrings("CLIENT", core.getField(fslice, 56).?);
    // Sequence number must be 1.
    try std.testing.expectEqualStrings("1", core.getField(fslice, 34).?);
    // Checksum must be valid.
    // (Already consumed from recv_buf; we need to re-verify from raw.)
    // Instead, verify that verifyChecksum returned true during parsing.

    // Logout to trigger server close.
    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "5", &.{});
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "behav: NewOrderSingle body fields are preserved in echo" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 1);

    const sa = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 1);
    const stream = try sa.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var rd_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);
    var recv_buf: [core.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;
    var out_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var fields: [core.MAX_FIELDS]core.Field = undefined;
    var seq: u32 = 1;

    // Logon.
    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "A", &.{
        .{ .tag = 98, .value = "0" }, .{ .tag = 108, .value = "30" },
    });
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    // NewOrderSingle with specific body fields.
    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "D", &.{
        .{ .tag = 11, .value = "ORD999" },
        .{ .tag = 55, .value = "GOOG" },
        .{ .tag = 54, .value = "2" }, // Side: Sell
        .{ .tag = 38, .value = "500" },
    });
    const nf = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);
    const fslice = fields[0..nf];

    try std.testing.expectEqualStrings("D", core.getField(fslice, 35).?);
    try std.testing.expectEqualStrings("ORD999", core.getField(fslice, 11).?);
    try std.testing.expectEqualStrings("GOOG", core.getField(fslice, 55).?);
    try std.testing.expectEqualStrings("2", core.getField(fslice, 54).?);
    try std.testing.expectEqualStrings("500", core.getField(fslice, 38).?);

    // Logout.
    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "5", &.{});
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "behav: clean Logout causes no server-side error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 2);

    const sa = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 2);
    const stream = try sa.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var rd_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);
    var recv_buf: [core.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;
    var out_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var fields: [core.MAX_FIELDS]core.Field = undefined;
    var seq: u32 = 1;

    // Logon.
    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "A", &.{
        .{ .tag = 98, .value = "0" }, .{ .tag = 108, .value = "30" },
    });
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    // Immediate Logout.
    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "5", &.{});
    const nf = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);
    try std.testing.expectEqualStrings("5", core.getField(fields[0..nf], 35).?);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
