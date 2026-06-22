//! Edge tests: boundary conditions and error paths for FIX parsing and session.

const std = @import("std");
const zix = @import("zix");

const TEST_PORT: u16 = 19650;

// --------------------------------------------------------- //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn runSegmentedResponseServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    defer stream.close(io);

    var rd_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);
    var recv_buf: [zix.Fix.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;

    _ = recvMsg(&rd.interface, &recv_buf, &recv_len, &fields) catch return;

    var out_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    const n = zix.Fix.buildMessage(&out_buf, "SERVER", "CLIENT", 1, zix.Fix.MsgType.Logon, &.{
        .{ .tag = .EncryptMethod, .value = "0" },
        .{ .tag = .HeartBtInt, .value = "30" },
    }) catch return;

    const half = n / 2;
    wr.interface.writeAll(out_buf[0..half]) catch return;
    wr.interface.flush() catch return;
    wr.interface.writeAll(out_buf[half..n]) catch return;
    wr.interface.flush() catch return;
}

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    zix.Fix.serveConn(stream, io, "SERVER", .{}) catch |e| {
        if (e != error.ConnectionClosed and e != error.BrokenPipe) ctx.err = e;
    };
}

fn setup(io: std.Io, ctx: *ServerCtx, port: u16) !std.Thread {
    ctx.err = null;
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    ctx.listener = try addr.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    return std.Thread.spawn(.{ .stack_size = 512 * 1024 }, runServer, .{ ctx, io });
}

fn recvMsg(
    rd: *std.Io.Reader,
    recv_buf: []u8,
    recv_len: *usize,
    out_fields: []zix.Fix.Field,
) !usize {
    while (true) {
        if (zix.Fix.findMessageEnd(recv_buf[0..recv_len.*])) |end| {
            const raw = recv_buf[0..end];
            const nf = try zix.Fix.parseFields(raw, out_fields);
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

// --------------------------------------------------------- //
// Config edge cases

test "zix edge: FixClientConfig, recv_timeout_ms = 0 disables timeout (default)" {
    const cfg = zix.Fix.ClientConfig{
        .ip = "127.0.0.1",
        .port = 9500,
        .comp_id = "CLIENT",
        .target_comp_id = "SERVER",
    };
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
}

test "zix edge: FixClientConfig, large recv_timeout_ms value is stored without overflow" {
    const cfg = zix.Fix.ClientConfig{
        .ip = "127.0.0.1",
        .port = 9500,
        .comp_id = "CLIENT",
        .target_comp_id = "SERVER",
        .recv_timeout_ms = std.math.maxInt(u32),
    };
    try std.testing.expectEqual(std.math.maxInt(u32), cfg.recv_timeout_ms);
}

// --------------------------------------------------------- //
// Pure-computation edge cases (no I/O)

test "zix edge: parseFields handles maximum number of fields without panic" {
    var msg_buf: [zix.Fix.MAX_MSG_SIZE * 2]u8 = undefined;
    var pos: usize = 0;
    var i: u16 = 0;
    while (i < zix.Fix.MAX_FIELDS - 1) : (i += 1) {
        const s = std.fmt.bufPrint(msg_buf[pos..], "{d}=v\x01", .{1000 + i}) catch break;
        pos += s.len;
    }
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    const n = try zix.Fix.parseFields(msg_buf[0..pos], &fields);
    try std.testing.expect(n <= zix.Fix.MAX_FIELDS);
}

test "zix edge: verifyChecksum returns false for truncated message" {
    const msg = "8=FIX.4.2\x019=5\x0135=A\x0110=12";
    try std.testing.expect(!zix.Fix.verifyChecksum(msg));
}

test "zix edge: findMessageEnd returns null for message with tag 10 value but no final SOH" {
    const msg = "8=FIX.4.2\x019=5\x0135=A\x0110=123";
    try std.testing.expect(zix.Fix.findMessageEnd(msg) == null);
}

test "zix edge: buildMessage with zero extra fields produces valid message" {
    var out: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    const n = try zix.Fix.buildMessage(&out, "S", "C", 1, "0", &.{});
    try std.testing.expect(n > 0);
    try std.testing.expect(zix.Fix.verifyChecksum(out[0..n]));
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    const nf = try zix.Fix.parseFields(out[0..n], &fields);
    try std.testing.expectEqualStrings("0", zix.Fix.getField(fields[0..nf], .MsgType).?);
}

// --------------------------------------------------------- //
// Session edge cases (with I/O)

test "zix edge: message arriving in two TCP segments is reassembled correctly" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT);

    const sa = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT);
    const stream = try sa.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);
    var recv_buf: [zix.Fix.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;
    var out_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;

    const logon_n = try zix.Fix.buildMessage(&out_buf, "CLIENT", "SERVER", 1, "A", &.{
        .{ .tag = .EncryptMethod, .value = "0" }, .{ .tag = .HeartBtInt, .value = "30" },
    });
    const half = logon_n / 2;
    try wr.interface.writeAll(out_buf[0..half]);
    try wr.interface.flush();
    try wr.interface.writeAll(out_buf[half..logon_n]);
    try wr.interface.flush();

    const nf = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);
    try std.testing.expectEqualStrings("A", zix.Fix.getField(fields[0..nf], .MsgType).?);

    const logout_n = try zix.Fix.buildMessage(&out_buf, "CLIENT", "SERVER", 2, "5", &.{});
    try wr.interface.writeAll(out_buf[0..logout_n]);
    try wr.interface.flush();
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix edge: FixClient.recvMessage reassembles server response split across two TCP segments" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    ctx.err = null;
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 2);
    ctx.listener = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 4 });
    const thread = try std.Thread.spawn(
        .{ .stack_size = 512 * 1024 },
        runSegmentedResponseServer,
        .{ &ctx, io },
    );

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = TEST_PORT + 2,
        .comp_id = "CLIENT",
        .target_comp_id = "SERVER",
    }, io);
    defer client.deinit(io);

    try client.sendMessage(io, zix.Fix.MsgType.Logon, &.{
        .{ .tag = .EncryptMethod, .value = "0" },
        .{ .tag = .HeartBtInt, .value = "30" },
    });

    const raw = try client.recvMessage(io);
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    const nf = try zix.Fix.parseFields(raw, &fields);
    try std.testing.expectEqualStrings(zix.Fix.MsgType.Logon, zix.Fix.getField(fields[0..nf], .MsgType).?);

    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix edge: bad checksum causes server to close without server-side error propagation" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 1);

    const sa = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 1);
    const stream = try sa.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    var out_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    const n = try zix.Fix.buildMessage(&out_buf, "CLIENT", "SERVER", 1, "A", &.{
        .{ .tag = .EncryptMethod, .value = "0" }, .{ .tag = .HeartBtInt, .value = "30" },
    });
    out_buf[n / 2] ^= 0xFF;

    try wr.interface.writeAll(out_buf[0..n]);
    try wr.interface.flush();

    _ = rd.interface.takeByte() catch {};

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
