//! ZIX example channel ipc b
//!
//! ### file: examples/channel_ipc_b.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Two-way IPC over a unix-domain socket, side B (client). B connects to
//! `tmp/zix_ipc.sock` opened by side A, then sends "B:N" every 400 ms and prints what
//! A sends.
//!
//! ### note:
//!
//! Start `channel_ipc_a` first, then run B in a second terminal, both from the same
//! working directory. B sends at a different rate from A to show both sides are
//! independent. Stop either side (Ctrl-C) and the other side sees the closed connection
//! and exits.
//! Run: `zig build zix-example-channel_ipc_b`, then the binary in `zig-out/bin`.
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
const SEND_INTERVAL_MS: i64 = 400;
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
        const message = std.fmt.bufPrint(&message_buf, "B:{d}", .{counter}) catch return;

        writeFrame(&stream_writer.interface, message) catch return;

        std.debug.print("B -> A  {s}\n", .{message});
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

        std.debug.print("A -> B  {s}\n", .{payload[0..len]});
    }
}

// --------------------------------------------------------- //

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Derived the same way side A derives it, so both ends agree on one absolute path.
    var path_buf: [600]u8 = undefined;
    const sock_path = try zix.utils.SocketPath.resolve(io, SOCK_DIR, SOCK_FILE, &path_buf);

    std.debug.print("B: connecting to {s}\n", .{sock_path});
    const unix_addr = try std.Io.net.UnixAddress.init(sock_path);
    const stream = try unix_addr.connect(io);
    defer stream.close(io);

    std.debug.print("B: connected, starting two-way exchange\n", .{});

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

    std.debug.print("B: connection closed\n", .{});
}

