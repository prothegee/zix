//! ZIX example uds server
//!
//! ### file: examples/uds_server.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! UDS data provider. Listens on `tmp/zix.sock` and replies to every frame with an
//! incrementing counter, so a frontend sees real data changes.
//!
//! ### note:
//!
//! Frame format (both directions): `[u32 payload_len, 4 bytes, big-endian][payload]`.
//! Run: `zig build zix-example-uds_server`, then the binary in `zig-out/bin`.
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
const SOCK_FILE: []const u8 = "zix.sock";
const FRAME_HEADER_LEN: usize = 4;
const MAX_PAYLOAD: usize = 256;

/// Counter shared by every connection, one step per received frame.
var g_counter = std.atomic.Value(u64).init(0);

// --------------------------------------------------------- //

/// Fill destination (dest) completely.
///
/// Return:
/// - true when destination is full
/// - false when the peer closed the connection first
fn readExact(reader: *std.Io.Reader, dest: []u8) std.Io.Reader.ShortError!bool {
    var filled: usize = 0;
    while (filled < dest.len) {
        const got = try reader.readSliceShort(dest[filled..]);
        if (got == 0) return false;

        filled += got;
    }

    return true;
}

/// Send one frame: a 4-byte big-endian length, then the payload.
fn writeFrame(writer: *std.Io.Writer, payload: []const u8) std.Io.Writer.Error!void {
    var header: [FRAME_HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);

    try writer.writeAll(&header);
    try writer.writeAll(payload);
    try writer.flush();
}

/// Read any frame (a "get" by convention) and reply with the current counter.
fn dataHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var read_buf: [256]u8 = undefined;
    var write_buf: [64]u8 = undefined;
    var payload: [MAX_PAYLOAD]u8 = undefined;

    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);

    while (true) {
        var header: [FRAME_HEADER_LEN]u8 = undefined;
        const has_header = readExact(&stream_reader.interface, &header) catch return;
        if (!has_header) return;

        const len = std.mem.readInt(u32, &header, .big);
        if (len > payload.len) return;

        const has_payload = readExact(&stream_reader.interface, payload[0..len]) catch return;
        if (!has_payload) return;

        const count = g_counter.fetchAdd(1, .monotonic);
        var reply_buf: [32]u8 = undefined;
        const reply = std.fmt.bufPrint(&reply_buf, "{d}", .{count}) catch return;

        writeFrame(&stream_writer.interface, reply) catch return;

        std.debug.print("uds_server: sent count={d}\n", .{count});
    }
}

// --------------------------------------------------------- //

pub fn main(init: std.process.Init) !void {
    // Uncomment to attach a console logger (UDS lifecycle logging):
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .console = .ALWAYS,
    //     .console_min_level = .INFO,
    // });
    // defer logger.deinit();

    // Absolute path: Windows rejects a relative one at bind time, and a client derives
    // the same string from the same working directory.
    var path_buf: [600]u8 = undefined;
    const sock_path = try zix.utils.SocketPath.resolve(init.io, SOCK_DIR, SOCK_FILE, &path_buf);

    var server = try zix.Uds.Server.init(dataHandler, .{
        .io = init.io,
        .allocator = std.heap.smp_allocator,
        .path = sock_path,
        // .logger = &logger,
    });
    defer server.deinit();

    try server.run();
}

