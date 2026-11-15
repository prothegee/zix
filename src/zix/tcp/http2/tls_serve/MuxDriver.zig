//! ZIX http2 tls serve mux driver
//!
//! ### file: src/zix/tcp/http2/tls_serve/MuxDriver.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The h2 terminator driver of the .ASYNC path: drives the resumable h2 mux
//! inline over a decrypted TLS connection on a blocking fd.
//!
//! ### note:
//!
//! Read a record, decrypt it, feed the mux, seal its reply frames back into
//! records through the writer write_hook. No socketpair and no second thread.
//! Generic over the connection, so TLS 1.3 and TLS 1.2 share it: both expose
//! readAppData, writeAppData, and closeNotify.
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
const tlz = @import("tlz");
const h2_terminator = @import("../../../tls/h2_terminator.zig");
const mux_dispatch = @import("../mux/mux_dispatch.zig");
const process = @import("../mux/process.zig");
const writer = @import("../writer.zig");
const HandlerFn = @import("../handler.zig").HandlerFn;
const MuxConn = @import("../mux/MuxConn.zig");
const ServeOpts = @import("../ServeOpts.zig");

// --------------------------------------------------------- //
// Fields:

handler: HandlerFn,
/// Mux limits of the connection.
opts: ServeOpts,
/// Worker io, carried onto every handler Context.
io: std.Io,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const CONTENT_CHANGE_CIPHER_SPEC: u8 = @intFromEnum(tlz.ContentType.CHANGE_CIPHER_SPEC);
const CONTENT_APPLICATION_DATA: u8 = @intFromEnum(tlz.ContentType.APPLICATION_DATA);

/// Decrypted plaintext of one record (inner content type included).
const RECORD_PLAIN_SIZE: usize = 17 * 1024;

/// One sealed record: a full plaintext record plus its AEAD overhead.
const SEALED_RECORD_SIZE: usize = tlz.sealedLen(tlz.MAX_PLAINTEXT);

/// close_notify staging.
const CLOSE_NOTIFY_SIZE: usize = 64;

/// The seal sink over one connection type: the mux writes plaintext frames,
/// whole records are sealed and written to fd.
fn SealSink(comptime Conn: type) type {
    return struct {
        conn: Conn,
        fd: std.posix.fd_t,
        plain: [tlz.MAX_PLAINTEXT]u8 = undefined,
        plain_len: usize = 0,
        /// A write failed: the peer is gone, the driver stops.
        failed: bool = false,

        const Sink = @This();

        fn flush(sink: *Sink) void {
            if (sink.plain_len == 0 or sink.failed) return;

            var sealed: [SEALED_RECORD_SIZE]u8 = undefined;
            const cipher = sink.conn.writeAppData(sink.plain[0..sink.plain_len], &sealed);
            sink.plain_len = 0;

            if (cipher.len == 0) {
                sink.failed = true;

                return;
            }

            h2_terminator.writeAll(sink.fd, cipher) catch |err| switch (err) {
                else => sink.failed = true,
            };
        }

        fn append(sink: *Sink, bytes: []const u8) void {
            var rest = bytes;

            while (rest.len > 0 and !sink.failed) {
                if (sink.plain_len == sink.plain.len) sink.flush();
                if (sink.failed) return;

                const take = @min(rest.len, sink.plain.len - sink.plain_len);
                @memcpy(sink.plain[sink.plain_len..][0..take], rest[0..take]);

                sink.plain_len += take;
                rest = rest[take..];
            }
        }

        fn hook(ctx_ptr: *anyopaque, bytes: []const u8) void {
            const sink: *Sink = @ptrCast(@alignCast(ctx_ptr));

            sink.append(bytes);
        }
    };
}

/// Append plaintext to the mux in parts that fit, processing each part.
///
/// Return:
/// - bool (false when the mux asks to close or a frame can never fit)
fn feedMux(handler_fn: HandlerFn, h2: *MuxConn, plaintext: []const u8, sink: anytype) bool {
    var rest = plaintext;

    while (rest.len > 0) {
        const take = h2.makeRoom(rest.len);
        if (take == 0) return false;

        @memcpy(h2.rbuf[h2.rend..][0..take], rest[0..take]);
        h2.rend += take;
        rest = rest[take..];

        const outcome = process.processRing(handler_fn, h2);
        sink.flush();

        if (sink.failed or outcome == .close) return false;
    }

    return true;
}

// --------------------------------------------------------- //
// Public:

/// Serve the decrypted h2 stream until the peer leaves or the mux closes.
///
/// Note:
/// - A peer that leaves with a request part way through gets GOAWAY, sealed
///   like any other frame, exactly as the cleartext models answer it.
/// - Ends with close_notify. The caller closes fd.
///
/// Param:
/// fd - std.posix.fd_t (the blocking connection socket)
/// conn - anytype (pointer to the established TLS 1.3 or TLS 1.2 connection)
/// record_buf - []u8 (one record of wire bytes, reused for every read)
pub fn drive(self: Self, fd: std.posix.fd_t, conn: anytype, record_buf: []u8) void {
    const h2 = MuxConn.init(fd, self.opts, self.io) catch |err| switch (err) {
        error.ZixHttp2_MuxConn_OutOfMemory => return,
    };
    defer h2.deinit();

    var sink: SealSink(@TypeOf(conn)) = .{
        .conn = conn,
        .fd = fd,
    };

    writer.write_hook = SealSink(@TypeOf(conn)).hook;
    writer.write_hook_ctx = &sink;
    defer {
        writer.write_hook = null;
        writer.write_hook_ctx = null;
    }

    var plain: [RECORD_PLAIN_SIZE]u8 = undefined;
    while (true) {
        const rec = h2_terminator.readRecord(fd, record_buf) catch |err| switch (err) {
            else => {
                _ = mux_dispatch.hangupGoaway(h2);
                sink.flush();

                break;
            },
        };
        if (rec.content_type == CONTENT_CHANGE_CIPHER_SPEC) continue;
        // An alert, close_notify included, ends the connection.
        if (rec.content_type != CONTENT_APPLICATION_DATA) break;

        const got = conn.readAppData(rec.full, &plain) catch |err| switch (err) {
            else => break,
        };

        if (!feedMux(self.handler, h2, got, &sink)) break;
    }

    var close_buf: [CLOSE_NOTIFY_SIZE]u8 = undefined;
    h2_terminator.writeAll(fd, conn.closeNotify(&close_buf)) catch |err| switch (err) {
        // Best effort: the connection is ending either way.
        else => {},
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const frame = @import("../frame.zig");
const pair = @import("../../../utils/socket/pair.zig");
const router = @import("../router.zig");
const HpackEncoder = @import("../hpack/HpackEncoder.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const Context = @import("../Context.zig");

/// A connection that frames records without encrypting them, so the driver
/// loop runs over a socketpair with no handshake.
const PlainConn = struct {
    fn readAppData(_: *PlainConn, rec: []const u8, out: []u8) error{Short}![]const u8 {
        const body = rec[5..];
        if (body.len > out.len) return error.Short;

        @memcpy(out[0..body.len], body);

        return out[0..body.len];
    }

    fn writeAppData(_: *PlainConn, plaintext: []const u8, out: []u8) []const u8 {
        if (plaintext.len + 5 > out.len) return &.{};

        out[0] = CONTENT_APPLICATION_DATA;
        std.mem.writeInt(u16, out[1..3], 0x0303, .big);
        std.mem.writeInt(u16, out[3..5], @intCast(plaintext.len), .big);
        @memcpy(out[5..][0..plaintext.len], plaintext);

        return out[0 .. 5 + plaintext.len];
    }

    fn closeNotify(_: *PlainConn, out: []u8) []const u8 {
        const alert = "\x15\x03\x03\x00\x02\x01\x00";
        @memcpy(out[0..alert.len], alert);

        return out[0..alert.len];
    }
};

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    try res.sendText("ok");
}

const ok_router = router.Router(&[_]router.Route{
    .{
        .path = "/",
        .handler = okHandler,
    },
});

const TestDriver = struct {
    fn run(fd: std.posix.fd_t) void {
        var conn: PlainConn = .{};
        var record_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;
        const driver: Self = .{
            .handler = ok_router.dispatch,
            .opts = .{
                .max_streams = 4,
            },
            .io = std.testing.io,
        };

        driver.drive(fd, &conn, &record_buf);
        _ = std.posix.system.close(fd);
    }
};

/// Frame plaintext as one record and write it.
fn sendRecord(fd: std.posix.fd_t, plaintext: []const u8) !void {
    var conn: PlainConn = .{};
    var out: [1024]u8 = undefined;

    try h2_terminator.writeAll(fd, conn.writeAppData(plaintext, &out));
}

/// Read records until close_notify and count HEADERS frames and alerts.
fn readUntilClose(fd: std.posix.fd_t) !struct { headers: usize, alerts: usize } {
    var headers: usize = 0;
    var alerts: usize = 0;
    var record_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;

    while (true) {
        const rec = h2_terminator.readRecord(fd, &record_buf) catch break;
        if (rec.content_type != CONTENT_APPLICATION_DATA) {
            alerts += 1;
            break;
        }

        var off: usize = 0;
        while (off + frame.FRAME_HEADER_LEN <= rec.body.len) {
            const header = frame.parseFrameHeader(rec.body[off..][0..frame.FRAME_HEADER_LEN]);
            if (header.frame_type == frame.FRAME_TYPE_HEADERS) headers += 1;

            off += frame.FRAME_HEADER_LEN + header.length;
        }
    }

    return .{
        .headers = headers,
        .alerts = alerts,
    };
}

test "zix http2: MuxDriver, answers a GET and ends with close_notify" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    const thread = try std.Thread.spawn(.{}, TestDriver.run, .{fds[1]});

    var plain: [256]u8 = undefined;
    var len: usize = 0;
    @memcpy(plain[0..frame.PREFACE.len], frame.PREFACE);
    len += frame.PREFACE.len;
    frame.encodeFrameHeader(plain[len..][0..frame.FRAME_HEADER_LEN], .{
        .length = 0,
        .frame_type = frame.FRAME_TYPE_SETTINGS,
        .flags = 0,
        .stream_id = 0,
    });
    len += frame.FRAME_HEADER_LEN;

    var block: [64]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "GET");
    try encoder.writeHeader(":path", "/");
    const head = encoder.encoded();
    frame.encodeFrameHeader(plain[len..][0..frame.FRAME_HEADER_LEN], .{
        .length = @intCast(head.len),
        .frame_type = frame.FRAME_TYPE_HEADERS,
        .flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM,
        .stream_id = 1,
    });
    len += frame.FRAME_HEADER_LEN;
    @memcpy(plain[len..][0..head.len], head);
    len += head.len;

    try sendRecord(fds[0], plain[0..len]);
    const shut_rc = std.os.linux.shutdown(fds[0], std.os.linux.SHUT.WR);
    try std.testing.expect(std.posix.errno(shut_rc) == .SUCCESS);

    const seen = try readUntilClose(fds[0]);
    thread.join();

    try std.testing.expectEqual(@as(usize, 1), seen.headers);
    try std.testing.expectEqual(@as(usize, 1), seen.alerts);
}

test "zix http2: MuxDriver, an alert record ends the connection" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    const thread = try std.Thread.spawn(.{}, TestDriver.run, .{fds[1]});

    try h2_terminator.writeAll(fds[0], "\x15\x03\x03\x00\x02\x01\x00");

    const seen = try readUntilClose(fds[0]);
    thread.join();

    try std.testing.expectEqual(@as(usize, 0), seen.headers);
    try std.testing.expectEqual(@as(usize, 1), seen.alerts);
}

test "zix http2: MuxDriver, a bad preface closes without an answer" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    const thread = try std.Thread.spawn(.{}, TestDriver.run, .{fds[1]});

    try sendRecord(fds[0], "GET / HTTP/1.1\r\nHost: x\r\n\r\nxxxxxxxxxx");

    const seen = try readUntilClose(fds[0]);
    thread.join();

    try std.testing.expectEqual(@as(usize, 0), seen.headers);
    try std.testing.expect(writer.write_hook == null);
}

test "zix http2: MuxDriver, SealSink splits a write wider than one record" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var conn: PlainConn = .{};
    var sink: SealSink(*PlainConn) = .{
        .conn = &conn,
        .fd = fds[1],
    };

    const wide: [tlz.MAX_PLAINTEXT + 10]u8 = @splat('w');
    sink.append(&wide);
    sink.flush();

    var record_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;
    const first = try h2_terminator.readRecord(fds[0], &record_buf);
    try std.testing.expectEqual(tlz.MAX_PLAINTEXT, first.body.len);

    const second = try h2_terminator.readRecord(fds[0], &record_buf);
    try std.testing.expectEqual(@as(usize, 10), second.body.len);
    try std.testing.expect(!sink.failed);
}

test "zix http2: MuxDriver, SealSink on a closed fd marks failed" {
    var conn: PlainConn = .{};
    var sink: SealSink(*PlainConn) = .{
        .conn = &conn,
        .fd = -1,
    };

    sink.append("x");
    sink.flush();

    try std.testing.expect(sink.failed);
}

