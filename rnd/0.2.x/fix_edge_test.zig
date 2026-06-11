//! Edge tests: boundary conditions and error paths for FIX parsing and session.
//! Run: zig test rnd/fix_edge_test.zig

const std = @import("std");
const core = @import("fix_poc_core.zig");

const TEST_PORT: u16 = 19550;

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

// ------------------------------------------------------------------- //
// Pure-computation edge cases (no I/O)                                //
// ------------------------------------------------------------------- //

test "edge: parseFields handles maximum number of fields without panic" {
    // Build a message with MAX_FIELDS-1 body fields.
    var msg_buf: [core.MAX_MSG_SIZE * 2]u8 = undefined;
    var pos: usize = 0;
    var i: u16 = 0;
    while (i < core.MAX_FIELDS - 1) : (i += 1) {
        const s = std.fmt.bufPrint(msg_buf[pos..], "{d}=v\x01", .{1000 + i}) catch break;
        pos += s.len;
    }
    var fields: [core.MAX_FIELDS]core.Field = undefined;
    const n = try core.parseFields(msg_buf[0..pos], &fields);
    try std.testing.expect(n <= core.MAX_FIELDS);
}

test "edge: verifyChecksum returns false for truncated message" {
    // Message cut off before the final SOH of tag 10.
    const msg = "8=FIX.4.2\x019=5\x0135=A\x0110=12"; // missing final SOH
    try std.testing.expect(!core.verifyChecksum(msg));
}

test "edge: findMessageEnd returns null for message with tag 10 value but no final SOH" {
    const msg = "8=FIX.4.2\x019=5\x0135=A\x0110=123"; // no trailing SOH
    try std.testing.expect(core.findMessageEnd(msg) == null);
}

test "edge: buildMessage with zero extra fields produces valid message" {
    var out: [core.MAX_MSG_SIZE]u8 = undefined;
    const n = try core.buildMessage(&out, "S", "C", 1, "0", &.{});
    try std.testing.expect(n > 0);
    try std.testing.expect(core.verifyChecksum(out[0..n]));
    var fields: [core.MAX_FIELDS]core.Field = undefined;
    const nf = try core.parseFields(out[0..n], &fields);
    try std.testing.expectEqualStrings("0", core.getField(fields[0..nf], 35).?);
}

// ------------------------------------------------------------------- //
// Session edge cases (with I/O)                                       //
// ------------------------------------------------------------------- //

test "edge: message arriving in two TCP segments is reassembled correctly" {
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

    // Build the Logon message manually, then send in two halves.
    const logon_n = try core.buildMessage(&out_buf, "CLIENT", "SERVER", 1, "A", &.{
        .{ .tag = 98, .value = "0" }, .{ .tag = 108, .value = "30" },
    });
    const half = logon_n / 2;
    try wr.interface.writeAll(out_buf[0..half]);
    try wr.interface.flush();
    try wr.interface.writeAll(out_buf[half..logon_n]);
    try wr.interface.flush();

    const nf = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);
    try std.testing.expectEqualStrings("A", core.getField(fields[0..nf], 35).?);

    // Logout.
    const logout_n = try core.buildMessage(&out_buf, "CLIENT", "SERVER", 2, "5", &.{});
    try wr.interface.writeAll(out_buf[0..logout_n]);
    try wr.interface.flush();
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: bad checksum causes server to close without server-side error propagation" {
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

    // Build a valid message then corrupt one byte in the body before sending.
    var out_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    const n = try core.buildMessage(&out_buf, "CLIENT", "SERVER", 1, "A", &.{
        .{ .tag = 98, .value = "0" }, .{ .tag = 108, .value = "30" },
    });
    out_buf[n / 2] ^= 0xFF; // corrupt a byte

    try wr.interface.writeAll(out_buf[0..n]);
    try wr.interface.flush();

    // Server closes the connection. Next read should return EOF or error.
    _ = rd.interface.takeByte() catch {}; // EOF or error is expected

    t.join();
    ctx.listener.deinit(io);
    // Server error may be set (it returned early), but it must not be a crash.
    // verifyChecksum failure causes a plain `return`, ctx.err stays null.
    try std.testing.expect(ctx.err == null);
}
