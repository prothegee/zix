//! zix tcp dispatch: helpers shared across the dispatch models (ADR-043).
//! Holds the per-connection primitive (ConnTask / dispatchConn), the
//! framed-engine wire format plus coalescing sink, and the small socket
//! helpers used by every model. Routes are runtime: each model threads a
//! HandlerFn function pointer, the framed ring bakes a comptime FrameFn.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig");
const TcpServerConfig = Config.TcpServerConfig;
const Logger = @import("../../logger/logger.zig").Logger;

/// Emit a server lifecycle line. Routes through cfg.logger when present.
/// Without a logger it prints to stderr only in Debug builds (silent in release).
pub fn logSystem(cfg: TcpServerConfig, comptime fmt: []const u8, args: anytype) void {
    if (cfg.logger) |lg| {
        lg.system(.INFO, "tcp", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix tcp: " ++ fmt ++ "\n", args);
}

/// Max epoll events drained per epoll_wait call. 512 lets a worker clear its
/// ready-fd set in one syscall at high connection counts.
pub const EPOLL_MAX_EVENTS: usize = 512;

// --------------------------------------------------------- //

/// User-provided connection handler. Receives the accepted stream and io.
/// The handler owns the stream for its lifetime. It must call stream.close(io) when done.
pub const HandlerFn = *const fn (stream: std.Io.net.Stream, io: std.Io) void;

/// Per-frame callback for the framed engine (runFramed). Called once per
/// length-prefixed frame (the engine drives the read/write loop, the callback
/// just processes one payload and writes a reply via frameRespond / writeAllFD).
/// Unlike HandlerFn it does not own the connection and never blocks, so it can
/// run on the single-threaded .URING completion ring (ADR-037).
pub const FrameFn = *const fn (payload: []const u8, fd: std.posix.fd_t) void;

/// Frame wire format for the framed engine: a 4-byte big-endian length prefix
/// followed by that many payload bytes. Frames larger than this are rejected
/// (the connection is closed).
pub const FRAME_LEN_PREFIX: usize = 4;
pub const FRAME_MAX_PAYLOAD: usize = 1 << 20;

// --------------------------------------------------------- //
// Framed-engine response sink + helpers. While a sink is installed
// (tl_resp_sink, the .URING ring path), writes stage into it and coalesce into
// one ring send, otherwise they go straight to the fd (the blocking adapter).

/// Direct socket write, bypassing the coalescing sink.
fn rawFrameWrite(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    var remaining = data;
    while (remaining.len > 0) {
        const rc = std.posix.system.write(fd, remaining.ptr, remaining.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;

                remaining = remaining[n..];
            },
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

/// Coalescing sink for the framed .URING path. Oversize writes flush straight to
/// the fd (safe under the ring's half-duplex guarantee).
pub const RespSink = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    len: usize = 0,
    failed: bool = false,

    pub fn append(self: *RespSink, bytes: []const u8) void {
        if (bytes.len > self.buf.len) {
            self.flush();
            rawFrameWrite(self.fd, bytes) catch {
                self.failed = true;
            };

            return;
        }

        if (self.len + bytes.len > self.buf.len) self.flush();

        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn flush(self: *RespSink) void {
        if (self.len == 0) return;

        rawFrameWrite(self.fd, self.buf[0..self.len]) catch {
            self.failed = true;
        };
        self.len = 0;
    }
};

/// Active sink for the current worker thread (set by the framed ring worker).
pub threadlocal var tl_resp_sink: ?*RespSink = null;

/// Write raw bytes to the connection: into the sink when one is installed
/// (coalesced ring send), otherwise straight to the fd.
pub fn writeAllFD(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    if (tl_resp_sink) |sink| {
        sink.append(data);

        return if (sink.failed) error.BrokenPipe else {};
    }

    return rawFrameWrite(fd, data);
}

/// Send a length-prefixed frame: a 4-byte big-endian length followed by payload.
/// The framed-engine reply helper for a FrameFn callback.
pub fn frameRespond(fd: std.posix.fd_t, payload: []const u8) error{BrokenPipe}!void {
    var hdr: [FRAME_LEN_PREFIX]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(payload.len), .big);

    try writeAllFD(fd, &hdr);
    try writeAllFD(fd, payload);
}

// --------------------------------------------------------- //

pub fn getPeerAddr(fd: std.posix.fd_t, buf: []u8) []const u8 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(fd, @ptrCast(&storage), &len) catch return "-";
    if (storage.family == std.posix.AF.INET) {
        const sock_in: *align(8) const std.posix.sockaddr.in = @ptrCast(&storage);
        const addr_bytes: [4]u8 = @bitCast(sock_in.addr);
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
            addr_bytes[0],                          addr_bytes[1], addr_bytes[2], addr_bytes[3],
            std.mem.bigToNative(u16, sock_in.port),
        }) catch "-";
    }
    return "-";
}

pub fn getMonotonicMs() u64 {
    var spec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &spec);
    const s: u64 = if (spec.sec >= 0) @intCast(spec.sec) else 0;
    const millis: u64 = if (spec.nsec >= 0) @as(u64, @intCast(spec.nsec)) / 1_000_000 else 0;
    return s * 1000 + millis;
}

pub fn applyConnTimeout(sock_fd: std.posix.fd_t, recv_ms: u32, send_ms: u32) void {
    if (recv_ms == 0 and send_ms == 0) return;

    if (recv_ms > 0) {
        const recv_tv = std.posix.timeval{ .sec = @intCast(recv_ms / 1000), .usec = @intCast((recv_ms % 1000) * 1000) };
        std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&recv_tv)) catch {};
    }

    if (send_ms > 0) {
        const send_tv = std.posix.timeval{ .sec = @intCast(send_ms / 1000), .usec = @intCast((send_ms % 1000) * 1000) };
        std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&send_tv)) catch {};
    }
}

// --------------------------------------------------------- //

pub const ConnTask = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    handler: HandlerFn,
    logger: ?*Logger,
};

pub fn dispatchConn(task: ConnTask) void {
    var peer_buf: [64]u8 = undefined;
    const peer = getPeerAddr(task.stream.socket.handle, &peer_buf);
    const start = getMonotonicMs();
    task.handler(task.stream, task.io);
    if (task.logger) |lg| lg.conn(peer, getMonotonicMs() - start, null);
}

// --------------------------------------------------------- //

/// Blocking adapter: wrap a FrameFn in a per-connection HandlerFn that reads
/// length-prefixed frames and dispatches each. Used for every dispatch model
/// other than .URING so runFramed works everywhere.
pub fn frameAdapter(comptime frame_fn: FrameFn) HandlerFn {
    return struct {
        fn handle(stream: std.Io.net.Stream, io: std.Io) void {
            defer stream.close(io);
            const fd = stream.socket.handle;

            const payload_buf = std.heap.smp_allocator.alloc(u8, FRAME_MAX_PAYLOAD) catch return;
            defer std.heap.smp_allocator.free(payload_buf);

            var read_buf: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buf);

            while (true) {
                const len = reader.interface.takeVarInt(u32, .big, FRAME_LEN_PREFIX) catch return;
                if (len == 0 or len > FRAME_MAX_PAYLOAD) return;

                reader.interface.readSliceAll(payload_buf[0..len]) catch return;

                frame_fn(payload_buf[0..len], fd);
            }
        }
    }.handle;
}
