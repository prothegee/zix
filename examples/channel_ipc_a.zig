//! ZIX example channel ipc a
//!
//! ### file: examples/channel_ipc_a.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Two-way IPC over a unix-domain socket, side A (server). A listens on
//! `tmp/zix_ipc.sock`, accepts side B, then sends "A:N" every 600 ms and prints what
//! B sends.
//!
//! ### note:
//!
//! Run A first, then `channel_ipc_b` in a second terminal, both from the same working
//! directory. Stop either side (Ctrl-C) and the other side sees the closed connection
//! and exits.
//! Run: `zig build zix-example-channel_ipc_a`, then the binary in `zig-out/bin`.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const SOCK_DIR: []const u8 = "tmp";
const SOCK_FILE: []const u8 = "zix_ipc.sock";
const SEND_INTERVAL_MS: i64 = 600;
const FRAME_HEADER_LEN: usize = 4;

const ThreadArgs = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
};

// --------------------------------------------------------- //

/// Send one frame: a 4-byte little-endian length, then the message bytes.
fn writeFrame(writer: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!void {
    var header: [FRAME_HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(message.len), .little);

    try writer.writeAll(&header);
    try writer.writeAll(message);
    try writer.flush();
}

/// Fill dst completely.
///
/// Return:
/// - true when dst is full
/// - false when the peer closed the connection first
fn readExact(reader: *std.Io.Reader, dst: []u8) std.Io.Reader.ShortError!bool {
    var filled: usize = 0;
    while (filled < dst.len) {
        const got = try reader.readSliceShort(dst[filled..]);
        if (got == 0) return false;

        filled += got;
    }

    return true;
}

fn sendLoop(args: ThreadArgs) void {
    var write_buf: [256]u8 = undefined;
    var stream_writer = args.stream.writer(args.io, &write_buf);
    var counter: u64 = 0;

    while (true) {
        var message_buf: [32]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "A:{d}", .{counter}) catch return;

        writeFrame(&stream_writer.interface, message) catch return;

        std.debug.print("A -> B  {s}\n", .{message});
        counter += 1;

        const interval = std.Io.Duration.fromMilliseconds(SEND_INTERVAL_MS);
        std.Io.sleep(args.io, interval, .awake) catch return;
    }
}

fn receiveLoop(args: ThreadArgs) void {
    var read_buf: [4096]u8 = undefined;
    var payload: [4096]u8 = undefined;
    var stream_reader = args.stream.reader(args.io, &read_buf);

    while (true) {
        var header: [FRAME_HEADER_LEN]u8 = undefined;
        const has_header = readExact(&stream_reader.interface, &header) catch return;
        if (!has_header) return;

        const len = std.mem.readInt(u32, &header, .little);
        if (len > payload.len) return;

        const has_payload = readExact(&stream_reader.interface, payload[0..len]) catch return;
        if (!has_payload) return;

        std.debug.print("B -> A  {s}\n", .{payload[0..len]});
    }
}

// --------------------------------------------------------- //

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Absolute path: Windows rejects a relative one at bind time, and side B derives the
    // same string from the same working directory.
    var path_buf: [600]u8 = undefined;
    const sock_path = try zix.utils.SocketPath.resolve(io, SOCK_DIR, SOCK_FILE, &path_buf);

    zix.utils.SocketPath.clear(io, sock_path);

    const unix_addr = try std.Io.net.UnixAddress.init(sock_path);
    var net_server = try unix_addr.listen(io, .{ .kernel_backlog = 1 });
    defer {
        net_server.deinit(io);
        zix.utils.SocketPath.clear(io, sock_path);
    }

    std.debug.print("A: listening on {s}, start side B\n", .{sock_path});
    const stream = try net_server.accept(io);
    defer stream.close(io);

    std.debug.print("A: B connected, starting two-way exchange\n", .{});

    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const args: ThreadArgs = .{
        .stream = stream,
        .io = threaded.io(),
    };

    const send_thread = try std.Thread.spawn(.{}, sendLoop, .{args});
    const receive_thread = try std.Thread.spawn(.{}, receiveLoop, .{args});

    send_thread.join();
    receive_thread.join();

    std.debug.print("A: connection closed\n", .{});
}

