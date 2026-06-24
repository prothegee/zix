//! HTTP/2 multiplexed connection state machine for the .EPOLL / .URING dispatch models.
//!
//! What:
//! - Resumable, non-blocking h2c. One `MuxConn` per fd. The read accumulator `rbuf` persists across
//!   readable events and holds a partial frame until the rest arrives, so a worker can drive many
//!   connections from one thread. Mirrors the gRPC mux loop (`grpc/core.zig`), adapted to the plain
//!   h2c handler model.
//!
//! Note:
//! - Connection-management frames and responses write straight to the fd via the `frame.*` helpers,
//!   which poll on EAGAIN for a non-blocking socket (see `frame.fdWriteAll`). Wire order is preserved
//!   with no reply cork, and the existing `core` dispatch is reused unchanged. A handler runs inline
//!   on the worker, so like the gRPC mux model it must stay bounded.
//! - The h2c upgrade path (HTTP/1.1 `Upgrade: h2c`) is served minimally on the mux path: 101 then the
//!   connection preface, the request carried on stream 1 is not served (prior-knowledge clients, the
//!   common h2c case, are unaffected). The blocking POOL / ASYNC / MIXED models serve it.

const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const core = @import("core.zig");

const Route = core.Route;

// --------------------------------------------------------- //

pub const ConnOutcome = enum { keep_alive, close };

const MuxPhase = enum { await_preface, await_upgrade, await_preface2, h2 };

const StreamState = enum { IDLE, OPEN, HALF_CLOSED_REMOTE, CLOSED };

/// One stream within a multiplexed connection. `body` / `header_scratch` are slices into the
/// connection's shared backing buffers, sized by the serve options.
const MuxStream = struct {
    id: u31 = 0,
    state: StreamState = .IDLE,
    headers: [frame.MAX_HEADERS]hpack.Header = undefined,
    header_count: usize = 0,
    header_scratch: []u8 = &.{},
    body: []u8 = &.{},
    body_len: usize = 0,
    end_headers: bool = false,
    end_stream: bool = false,
};

/// Per-connection h2 state for the multiplexed models. Heap-owned, one per fd, private to the
/// owning worker thread.
pub const MuxConn = struct {
    fd: std.posix.fd_t,
    opts: core.ServeOpts,

    rbuf: []u8,
    rstart: usize,
    rend: usize,

    hpack_dec: hpack.HpackDecoder,

    streams: []MuxStream,
    slots: []bool,
    bodies: []u8,
    scratches: []u8,

    last_stream_id: u31,
    phase: MuxPhase,

    /// Allocate and initialize a connection. Returns null on allocation failure (caller closes fd).
    pub fn init(fd: std.posix.fd_t, opts: core.ServeOpts) ?*MuxConn {
        const a = std.heap.smp_allocator;
        const conn = a.create(MuxConn) catch return null;

        const max_payload = opts.max_frame_size + 256;
        const rcap = @max(32 * 1024, max_payload + 9);
        const rbuf = a.alloc(u8, rcap) catch {
            a.destroy(conn);
            return null;
        };
        const streams = a.alloc(MuxStream, opts.max_streams) catch {
            a.free(rbuf);
            a.destroy(conn);
            return null;
        };
        const slots = a.alloc(bool, opts.max_streams) catch {
            a.free(streams);
            a.free(rbuf);
            a.destroy(conn);
            return null;
        };
        const bodies = a.alloc(u8, opts.max_body * opts.max_streams) catch {
            a.free(slots);
            a.free(streams);
            a.free(rbuf);
            a.destroy(conn);
            return null;
        };
        const scratches = a.alloc(u8, opts.max_header_scratch * opts.max_streams) catch {
            a.free(bodies);
            a.free(slots);
            a.free(streams);
            a.free(rbuf);
            a.destroy(conn);
            return null;
        };

        @memset(slots, false);
        for (streams, 0..) |*s, i| {
            s.* = .{};
            s.body = bodies[i * opts.max_body ..][0..opts.max_body];
            s.header_scratch = scratches[i * opts.max_header_scratch ..][0..opts.max_header_scratch];
        }

        conn.* = .{
            .fd = fd,
            .opts = opts,
            .rbuf = rbuf,
            .rstart = 0,
            .rend = 0,
            .hpack_dec = hpack.HpackDecoder.init(),
            .streams = streams,
            .slots = slots,
            .bodies = bodies,
            .scratches = scratches,
            .last_stream_id = 0,
            .phase = .await_preface,
        };

        return conn;
    }

    pub fn deinit(self: *MuxConn) void {
        const a = std.heap.smp_allocator;
        a.free(self.scratches);
        a.free(self.bodies);
        a.free(self.slots);
        a.free(self.streams);
        a.free(self.rbuf);
        a.destroy(self);
    }
};

// --------------------------------------------------------- //

fn slotFor(stream_id: u31, streams: []MuxStream, used: []bool) ?usize {
    for (used, 0..) |slot_in_use, i| {
        if (!slot_in_use) {
            used[i] = true;
            streams[i].id = stream_id;
            return i;
        }
    }

    return null;
}

fn findSlot(stream_id: u31, streams: []MuxStream, used: []bool) ?usize {
    for (used, 0..) |slot_in_use, i| {
        if (slot_in_use and streams[i].id == stream_id) return i;
    }

    return null;
}

/// Send the server SETTINGS frame (the connection preface reply).
fn sendServerSettings(conn: *MuxConn) void {
    frame.sendSettings(conn.fd, &.{
        .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(conn.opts.max_streams)) },
        .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
        .{ frame.SETTINGS_MAX_FRAME_SIZE, conn.opts.max_frame_size },
        .{ frame.SETTINGS_ENABLE_PUSH, 0 },
    }) catch {};
}

/// Extract method / path from the decoded pseudo-headers and dispatch the stream. The reply is
/// written straight to the fd by the handler (via `frame.sendResponse`).
fn muxDispatch(comptime routes: []const Route, conn: *MuxConn, s: *MuxStream) void {
    var method: []const u8 = "GET";
    var path: []const u8 = "/";
    for (s.headers[0..s.header_count]) |h| {
        switch (h.name.len) {
            5 => if (std.mem.eql(u8, h.name, ":path")) {
                path = h.value;
            },
            7 => if (std.mem.eql(u8, h.name, ":method")) {
                method = h.value;
            },
            else => {},
        }
    }

    core.Router(routes).dispatch(method, path, s.headers[0..s.header_count], s.body[0..s.body_len], conn.fd, s.id);
}

/// Handle the HTTP/1.1 h2c upgrade request. Minimal: 101 then await the preface. The carried
/// stream-1 request is not served on the mux path.
fn muxHandleUpgrade(conn: *MuxConn) ConnOutcome {
    const buf = conn.rbuf[conn.rstart..conn.rend];
    const marker = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        if (conn.rend == conn.rbuf.len) return .close;
        return .keep_alive;
    };
    const hdr_end = marker + 4;

    const upgrade_val = getHttp1Header(buf[0..hdr_end], "upgrade");
    const is_h2c = upgrade_val != null and std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade_val.?, " "), "h2c");
    if (!is_h2c) {
        frame.fdWriteAll(conn.fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return .close;
    }

    frame.fdWriteAll(conn.fd, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n") catch {};
    conn.rstart += hdr_end;
    conn.phase = .await_preface2;

    return .keep_alive;
}

fn getHttp1Header(buf: []const u8, name: []const u8) ?[]const u8 {
    const first_crlf = std.mem.indexOf(u8, buf, "\r\n") orelse return null;
    var pos = first_crlf + 2;
    while (pos < buf.len) {
        const line_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse break;
        const line = buf[pos..line_end];
        if (line.len == 0) break;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                var val_start: usize = colon + 1;
                while (val_start < line.len and line[val_start] == ' ') val_start += 1;
                return line[val_start..];
            }
        }
        pos = line_end + 2;
    }

    return null;
}

/// Advance the connection through the preface phases, then process buffered frames.
fn muxProcess(comptime routes: []const Route, conn: *MuxConn) ConnOutcome {
    switch (conn.phase) {
        .await_preface => {
            const avail = conn.rend - conn.rstart;
            if (avail < 3) return .keep_alive;

            if (!std.mem.eql(u8, conn.rbuf[conn.rstart..][0..3], "PRI")) {
                conn.phase = .await_upgrade;
                return muxHandleUpgrade(conn);
            }
            if (avail < frame.PREFACE.len) return .keep_alive;
            if (!std.mem.eql(u8, conn.rbuf[conn.rstart..][0..frame.PREFACE.len], frame.PREFACE)) {
                frame.sendGoaway(conn.fd, 0, frame.ERR_PROTOCOL_ERROR) catch {};
                return .close;
            }

            conn.rstart += frame.PREFACE.len;
            sendServerSettings(conn);
            conn.phase = .h2;
        },

        .await_upgrade => return muxHandleUpgrade(conn),

        .await_preface2 => {
            const avail = conn.rend - conn.rstart;
            if (avail < frame.PREFACE.len) return .keep_alive;
            if (!std.mem.eql(u8, conn.rbuf[conn.rstart..][0..frame.PREFACE.len], frame.PREFACE)) {
                frame.sendGoaway(conn.fd, 0, frame.ERR_PROTOCOL_ERROR) catch {};
                return .close;
            }

            conn.rstart += frame.PREFACE.len;
            sendServerSettings(conn);
            conn.phase = .h2;
        },

        .h2 => {},
    }

    return muxFrameLoop(routes, conn);
}

/// The h2 frame loop over buffered bytes for a connection in the .h2 phase.
fn muxFrameLoop(comptime routes: []const Route, conn: *MuxConn) ConnOutcome {
    const max_payload = conn.opts.max_frame_size + 256;

    while (true) {
        const avail = conn.rend - conn.rstart;
        if (avail < 9) return .keep_alive;

        const fh = frame.parseFrameHeader(conn.rbuf[conn.rstart..][0..9]);
        if (fh.length > max_payload) {
            frame.sendGoaway(conn.fd, conn.last_stream_id, frame.ERR_FRAME_SIZE_ERROR) catch {};
            return .close;
        }
        if (avail < 9 + fh.length) return .keep_alive;

        conn.rstart += 9;
        const payload = conn.rbuf[conn.rstart..][0..fh.length];
        conn.rstart += fh.length;

        switch (fh.frame_type) {
            frame.FRAME_TYPE_SETTINGS => {
                if ((fh.flags & frame.FLAG_ACK) != 0) continue;
                var i: usize = 0;
                while (i + 6 <= payload.len) : (i += 6) {
                    const id: u16 = (@as(u16, payload[i]) << 8) | payload[i + 1];
                    const val: u32 = (@as(u32, payload[i + 2]) << 24) | (@as(u32, payload[i + 3]) << 16) |
                        (@as(u32, payload[i + 4]) << 8) | payload[i + 5];
                    if (id == frame.SETTINGS_HEADER_TABLE_SIZE) {
                        conn.hpack_dec.max_size = val;
                        conn.hpack_dec.evictTo(val);
                    }
                }
                frame.sendSettingsAck(conn.fd) catch {};
                frame.sendWindowUpdate(conn.fd, 0, 65535) catch {};
            },

            frame.FRAME_TYPE_WINDOW_UPDATE => {},

            frame.FRAME_TYPE_PING => {
                if ((fh.flags & frame.FLAG_ACK) != 0) continue;
                if (payload.len != 8) {
                    frame.sendGoaway(conn.fd, conn.last_stream_id, frame.ERR_FRAME_SIZE_ERROR) catch {};
                    return .close;
                }
                var p8: [8]u8 = undefined;
                @memcpy(&p8, payload[0..8]);
                frame.sendPingAck(conn.fd, p8) catch {};
            },

            frame.FRAME_TYPE_HEADERS => {
                const sid = fh.stream_id;
                if (sid == 0) {
                    frame.sendGoaway(conn.fd, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return .close;
                }
                if (sid <= conn.last_stream_id and sid % 2 == 1) {
                    frame.sendRstStream(conn.fd, sid, frame.ERR_STREAM_CLOSED) catch {};
                    continue;
                }
                conn.last_stream_id = @max(conn.last_stream_id, sid);

                const slot = slotFor(sid, conn.streams, conn.slots) orelse {
                    frame.sendRstStream(conn.fd, sid, frame.ERR_REFUSED_STREAM) catch {};
                    continue;
                };
                const s = &conn.streams[slot];
                s.id = sid;
                s.state = .OPEN;
                s.header_count = 0;
                s.body_len = 0;
                s.end_headers = false;
                s.end_stream = false;

                var block = payload;
                var offset: usize = 0;
                var pad_len: usize = 0;
                if ((fh.flags & frame.FLAG_PADDED) != 0 and block.len > 0) {
                    pad_len = block[0];
                    offset = 1;
                }
                if ((fh.flags & frame.FLAG_PRIORITY) != 0 and offset + 5 <= block.len) {
                    offset += 5;
                }
                if (pad_len + offset > block.len) {
                    frame.sendGoaway(conn.fd, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return .close;
                }
                block = block[offset .. block.len - pad_len];

                s.header_count = conn.hpack_dec.decode(block, &s.headers, s.header_scratch) catch {
                    frame.sendRstStream(conn.fd, sid, frame.ERR_COMPRESSION_ERROR) catch {};
                    conn.slots[slot] = false;
                    continue;
                };
                s.end_headers = (fh.flags & frame.FLAG_END_HEADERS) != 0;
                s.end_stream = (fh.flags & frame.FLAG_END_STREAM) != 0;

                if (s.end_headers and s.end_stream) {
                    muxDispatch(routes, conn, s);
                    conn.slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_CONTINUATION => {
                const sid = fh.stream_id;
                const slot = findSlot(sid, conn.streams, conn.slots) orelse {
                    frame.sendGoaway(conn.fd, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return .close;
                };
                const s = &conn.streams[slot];
                const count = conn.hpack_dec.decode(payload, s.headers[s.header_count..], s.header_scratch) catch {
                    frame.sendRstStream(conn.fd, sid, frame.ERR_COMPRESSION_ERROR) catch {};
                    conn.slots[slot] = false;
                    continue;
                };
                s.header_count += count;
                s.end_headers = (fh.flags & frame.FLAG_END_HEADERS) != 0;
                if (s.end_headers and s.end_stream) {
                    muxDispatch(routes, conn, s);
                    conn.slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_DATA => {
                const sid = fh.stream_id;
                if (sid == 0) {
                    frame.sendGoaway(conn.fd, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return .close;
                }
                const slot = findSlot(sid, conn.streams, conn.slots) orelse {
                    frame.sendRstStream(conn.fd, sid, frame.ERR_STREAM_CLOSED) catch {};
                    continue;
                };
                const s = &conn.streams[slot];

                var data = payload;
                var pad_len: usize = 0;
                if ((fh.flags & frame.FLAG_PADDED) != 0 and data.len > 0) {
                    pad_len = data[0];
                    data = data[1..];
                }
                if (pad_len > data.len) {
                    frame.sendGoaway(conn.fd, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return .close;
                }
                data = data[0 .. data.len - pad_len];

                if (data.len > 0) {
                    frame.sendWindowUpdate(conn.fd, 0, @intCast(data.len)) catch {};
                    frame.sendWindowUpdate(conn.fd, sid, @intCast(data.len)) catch {};
                }

                const to_copy = @min(data.len, s.body.len - s.body_len);
                @memcpy(s.body[s.body_len..][0..to_copy], data[0..to_copy]);
                s.body_len += to_copy;

                s.end_stream = (fh.flags & frame.FLAG_END_STREAM) != 0;
                if (s.end_stream) {
                    muxDispatch(routes, conn, s);
                    conn.slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_RST_STREAM => {
                if (findSlot(fh.stream_id, conn.streams, conn.slots)) |slot| conn.slots[slot] = false;
            },

            frame.FRAME_TYPE_GOAWAY => return .close,
            frame.FRAME_TYPE_PRIORITY => {},
            else => {},
        }
    }
}

/// Process the bytes already in `rbuf` for a connection whose read accumulator a ring recv has just
/// filled. Unlike `onReadable` there is no read loop and no fd flush at the end: the .URING worker
/// owns the recv and re-arms it after this returns. Responses and connection frames are written
/// straight to the fd during processing, exactly as on the .EPOLL path.
///
/// Return:
/// - .close when a protocol error occurred or the handshake was rejected
pub fn processRing(comptime routes: []const Route, conn: *MuxConn) ConnOutcome {
    return muxProcess(routes, conn);
}

/// Drive one readable event: read available bytes (non-blocking), then process complete frames.
/// Responses and connection frames are written straight to the fd during processing.
///
/// Return:
/// - .close when the peer closed, a protocol error occurred, or the handshake was rejected
pub fn onReadable(comptime routes: []const Route, conn: *MuxConn) ConnOutcome {
    while (true) {
        if (conn.rstart == conn.rend) {
            conn.rstart = 0;
            conn.rend = 0;
        } else if (conn.rend == conn.rbuf.len) {
            const n = conn.rend - conn.rstart;
            std.mem.copyForwards(u8, conn.rbuf[0..n], conn.rbuf[conn.rstart..conn.rend]);
            conn.rstart = 0;
            conn.rend = n;
        }

        if (conn.rend == conn.rbuf.len) return .close;

        const got = std.posix.read(conn.fd, conn.rbuf[conn.rend..]) catch |err| switch (err) {
            error.WouldBlock => return .keep_alive,
            else => return .close,
        };
        if (got == 0) return .close;
        conn.rend += got;

        if (muxProcess(routes, conn) == .close) return .close;
    }
}
