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

/// The connection whose handler is running on this worker thread, set around each dispatch so the
/// flow-controlled send (`sendResponseStream`) can reach the connection's send windows. Null on the
/// blocking non-mux serve paths, where the send falls back to an immediate, unmetered write.
pub threadlocal var active_conn: ?*MuxConn = null;

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

    /// Send-side flow control (RFC 7540 6.9). send_window is the peer's remaining receive window for
    /// this stream. pending_body is the still-unsent tail of a response body whose send was capped by
    /// a window. It points into caller-owned memory that must outlive the stream (the static cache),
    /// the slot stays allocated until pending_body drains, and a WINDOW_UPDATE resumes it.
    send_window: i64 = 65535,
    pending_body: []const u8 = &.{},
    pending_end: bool = false,
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

    /// Connection-level send window (the peer's remaining receive window for all our DATA), and the
    /// peer's advertised SETTINGS_INITIAL_WINDOW_SIZE, the starting per-stream send window. Both
    /// govern how much response body we may send before a WINDOW_UPDATE.
    send_window: i64 = 65535,
    peer_init_window: i64 = 65535,

    /// Allocate and initialize a connection. Returns null on allocation failure (caller closes fd).
    pub fn init(fd: std.posix.fd_t, opts: core.ServeOpts) ?*MuxConn {
        const a = std.heap.smp_allocator;
        const conn = a.create(MuxConn) catch return null;

        const max_payload = opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;
        const rcap = @max(opts.conn_read_buf_min, max_payload + 9);
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
fn muxDispatch(comptime routes: []const Route, conn: *MuxConn, slot: usize) void {
    const s = &conn.streams[slot];
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

    active_conn = conn;
    // Record the request key inputs for the response-cache API only when a cache is installed, so the
    // default (cache off) hot path pays no extra threadlocal writes. serveCached returns false without
    // a cache, so it never reads these when they go unset, and the next dispatch overwrites them.
    if (core.tl_cache != null) {
        core.tl_req_path = path;
        core.tl_req_body = s.body[0..s.body_len];
    }
    core.Router(routes).dispatch(method, path, s.headers[0..s.header_count], s.body[0..s.body_len], conn.fd, s.id);
    active_conn = null;

    // Free the slot unless the response body is parked on a window, then a WINDOW_UPDATE resumes it.
    if (s.pending_body.len == 0) conn.slots[slot] = false;
}

/// Send DATA for `body` up to the connection and stream send windows and the max frame size. What
/// does not fit is parked on the stream (`pending_body`) for a later WINDOW_UPDATE. END_STREAM rides
/// the final frame only once the whole body has gone out.
fn pumpBody(conn: *MuxConn, stream: *MuxStream, body: []const u8, end: bool) void {
    var off: usize = 0;
    while (off < body.len) {
        const room = @min(conn.send_window, stream.send_window);
        if (room <= 0) break;

        const cap = @min(@as(i64, conn.opts.max_frame_size), room);
        const chunk = @min(body.len - off, @as(usize, @intCast(cap)));
        const is_last = end and (off + chunk == body.len);

        frame.writeFrameHeader(conn.fd, .{
            .length = @intCast(chunk),
            .frame_type = frame.FRAME_TYPE_DATA,
            .flags = if (is_last) frame.FLAG_END_STREAM else 0,
            .stream_id = stream.id,
        }) catch break;
        frame.fdWriteAll(conn.fd, body[off..][0..chunk]) catch break;

        conn.send_window -= @intCast(chunk);
        stream.send_window -= @intCast(chunk);
        off += chunk;
    }

    if (off < body.len) {
        stream.pending_body = body[off..];
        stream.pending_end = end;
    } else {
        stream.pending_body = &.{};
        stream.pending_end = false;
    }
}

/// Resume one parked stream after its window grew. Frees the slot once the body fully drains.
fn resumeStream(conn: *MuxConn, slot: usize) void {
    const stream = &conn.streams[slot];
    if (stream.pending_body.len == 0) return;

    pumpBody(conn, stream, stream.pending_body, stream.pending_end);
    if (stream.pending_body.len == 0) conn.slots[slot] = false;
}

/// Resume every parked stream after the connection window grew.
fn resumeAll(conn: *MuxConn) void {
    for (conn.slots, 0..) |in_use, slot| {
        if (in_use and conn.streams[slot].pending_body.len > 0) resumeStream(conn, slot);
    }
}

/// Write the response HEADERS frame (status, content-type, optional content-encoding, content-length).
fn sendRespHeaders(fd: std.posix.fd_t, sid: u31, status: u16, content_type: []const u8, content_encoding: []const u8, content_length: usize, end_stream: bool) void {
    var hdr_buf: [frame.HPACK_ENCODE_SCRATCH]u8 = undefined;
    var enc = hpack.HpackEncoder.init(&hdr_buf);

    var status_str: [4]u8 = undefined;
    const status_s = std.fmt.bufPrint(&status_str, "{d}", .{status}) catch "200";
    enc.writeHeader(":status", status_s) catch return;
    if (content_type.len > 0) enc.writeHeader("content-type", content_type) catch return;
    if (content_encoding.len > 0) enc.writeHeader("content-encoding", content_encoding) catch return;
    var cl_buf: [20]u8 = undefined;
    const cl_s = std.fmt.bufPrint(&cl_buf, "{d}", .{content_length}) catch "0";
    enc.writeHeader("content-length", cl_s) catch return;

    const hblock = enc.encoded();
    const flags: u8 = if (end_stream) frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM else frame.FLAG_END_HEADERS;

    frame.writeFrameHeader(fd, .{ .length = @intCast(hblock.len), .frame_type = frame.FRAME_TYPE_HEADERS, .flags = flags, .stream_id = sid }) catch return;
    frame.fdWriteAll(fd, hblock) catch return;
}

/// Send a response with HTTP/2 send-side flow control: HEADERS, then the body in DATA frames capped
/// by the peer's connection and stream windows, the remainder parked and resumed by WINDOW_UPDATE.
///
/// Note:
/// - The body is referenced, not copied, so it must outlive the stream (a process-lifetime cache, not
///   a per-request scratch buffer). For small transient bodies use frame.sendResponse instead.
/// - With no active connection context (the blocking non-mux serve paths) it falls back to an
///   immediate, unmetered send.
pub fn sendResponseStream(fd: std.posix.fd_t, sid: u31, status: u16, content_type: []const u8, content_encoding: []const u8, body: []const u8) void {
    const conn = active_conn orelse {
        frame.sendResponseEncoded(fd, sid, status, content_type, content_encoding, body) catch {};
        return;
    };
    const slot = if (conn.fd == fd) findSlot(sid, conn.streams, conn.slots) else null;
    const s = if (slot) |sl| &conn.streams[sl] else {
        frame.sendResponseEncoded(fd, sid, status, content_type, content_encoding, body) catch {};
        return;
    };

    sendRespHeaders(fd, sid, status, content_type, content_encoding, body.len, body.len == 0);
    if (body.len == 0) return;

    pumpBody(conn, s, body, true);
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
    const max_payload = conn.opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;

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
                    if (id == frame.SETTINGS_INITIAL_WINDOW_SIZE) {
                        // RFC 7540 6.9.2: a new initial window adjusts every open stream's send
                        // window by the delta.
                        const new_init: i64 = val;
                        const delta = new_init - conn.peer_init_window;
                        conn.peer_init_window = new_init;
                        for (conn.slots, 0..) |in_use, slot| {
                            if (in_use) conn.streams[slot].send_window += delta;
                        }
                    }
                }
                frame.sendSettingsAck(conn.fd) catch {};
                frame.sendWindowUpdate(conn.fd, 0, frame.DEFAULT_WINDOW_SIZE) catch {};
            },

            frame.FRAME_TYPE_WINDOW_UPDATE => {
                if (payload.len != 4) {
                    frame.sendGoaway(conn.fd, conn.last_stream_id, frame.ERR_FRAME_SIZE_ERROR) catch {};
                    return .close;
                }
                const raw: u32 = (@as(u32, payload[0]) << 24) | (@as(u32, payload[1]) << 16) |
                    (@as(u32, payload[2]) << 8) | payload[3];
                const inc: i64 = @intCast(raw & 0x7fffffff);

                if (fh.stream_id == 0) {
                    conn.send_window += inc;
                    resumeAll(conn);
                } else if (findSlot(fh.stream_id, conn.streams, conn.slots)) |slot| {
                    conn.streams[slot].send_window += inc;
                    resumeStream(conn, slot);
                }
            },

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
                s.send_window = conn.peer_init_window;
                s.pending_body = &.{};
                s.pending_end = false;

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
                    muxDispatch(routes, conn, slot);
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
                    muxDispatch(routes, conn, slot);
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
                    muxDispatch(routes, conn, slot);
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

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: mux sendResponseStream paces a large body by the send window" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    // the write end is closed explicitly below to signal EOF, so it is not deferred.

    const opts = core.ServeOpts{ .max_streams = 4, .max_body = 1024, .max_header_scratch = 1024 };
    const conn = MuxConn.init(fds[1], opts) orelse return error.OutOfMemory;
    defer conn.deinit();

    // tiny windows so a modest body must be paced across several WINDOW_UPDATEs
    conn.send_window = 100;
    conn.peer_init_window = 100;

    const slot = slotFor(1, conn.streams, conn.slots).?;
    const s = &conn.streams[slot];
    s.id = 1;
    s.state = .OPEN;
    s.send_window = 100;
    s.pending_body = &.{};

    var body: [250]u8 = undefined;
    @memset(&body, 'z');

    active_conn = conn;
    sendResponseStream(fds[1], 1, 200, "text/plain", "", &body);
    active_conn = null;

    // 100 of 250 went out, 150 parked, slot retained, connection window drained to 0
    try std.testing.expectEqual(@as(usize, 150), s.pending_body.len);
    try std.testing.expect(conn.slots[slot]);
    try std.testing.expectEqual(@as(i64, 0), conn.send_window);

    // grow the windows and resume: 100 more out, 50 parked, slot still held
    conn.send_window += 100;
    s.send_window += 100;
    resumeStream(conn, slot);
    try std.testing.expectEqual(@as(usize, 50), s.pending_body.len);
    try std.testing.expect(conn.slots[slot]);

    // grow again and resume: the last 50 go out with END_STREAM, the slot is freed
    conn.send_window += 100;
    s.send_window += 100;
    resumeStream(conn, slot);
    try std.testing.expectEqual(@as(usize, 0), s.pending_body.len);
    try std.testing.expect(!conn.slots[slot]);

    // drain the pipe: total DATA bytes equal the body, the final DATA frame carries END_STREAM, and
    // no single DATA frame exceeded the 100-byte window slice.
    _ = std.posix.system.close(fds[1]);
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const got = std.posix.read(fds[0], buf[total..]) catch break;
        if (got == 0) break;
        total += got;
    }

    var off: usize = 0;
    var data_bytes: usize = 0;
    var last_data_flags: u8 = 0;
    while (off + 9 <= total) {
        const fh = frame.parseFrameHeader(buf[off..][0..9]);
        off += 9;
        if (fh.frame_type == frame.FRAME_TYPE_DATA) {
            try std.testing.expect(fh.length <= 100);
            data_bytes += fh.length;
            last_data_flags = fh.flags;
        }
        off += fh.length;
    }

    try std.testing.expectEqual(@as(usize, 250), data_bytes);
    try std.testing.expect((last_data_flags & frame.FLAG_END_STREAM) != 0);
}

var fc_test_body: [5000]u8 = undefined;

fn fcTestHandler(_: []const u8, _: []const hpack.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    sendResponseStream(fd, sid, 200, "text/plain", "", &fc_test_body);
}

const fc_test_routes = [_]Route{.{ .path = "/", .handler = fcTestHandler }};

fn feedFrame(conn: *MuxConn, ftype: u8, flags: u8, sid: u31, payload: []const u8) void {
    var fh: [9]u8 = undefined;
    frame.encodeFrameHeader(&fh, .{ .length = @intCast(payload.len), .frame_type = ftype, .flags = flags, .stream_id = sid });
    @memcpy(conn.rbuf[conn.rend..][0..9], &fh);
    conn.rend += 9;
    @memcpy(conn.rbuf[conn.rend..][0..payload.len], payload);
    conn.rend += payload.len;
}

test "zix test: mux parks a body then resumes it across WINDOW_UPDATE in the frame loop" {
    @memset(&fc_test_body, 'q');

    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const opts = core.ServeOpts{ .max_streams = 4, .max_body = 256, .max_header_scratch = 1024 };
    const conn = MuxConn.init(fds[1], opts) orelse return error.OutOfMemory;
    defer conn.deinit();
    conn.phase = .h2;
    conn.send_window = 100;
    conn.peer_init_window = 100;

    // request: HEADERS GET / on stream 1, END_HEADERS | END_STREAM, which dispatches the handler
    var hblk: [128]u8 = undefined;
    var enc = hpack.HpackEncoder.init(&hblk);
    try enc.writeHeader(":method", "GET");
    try enc.writeHeader(":path", "/");
    feedFrame(conn, frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM, 1, enc.encoded());

    _ = muxFrameLoop(&fc_test_routes, conn);

    // the handler sent 100 of 5000 (the window) and parked the rest, the slot stays held
    const slot = findSlot(1, conn.streams, conn.slots).?;
    try std.testing.expectEqual(@as(usize, 4900), conn.streams[slot].pending_body.len);
    try std.testing.expectEqual(@as(i64, 0), conn.send_window);

    // grow the connection then the stream window by 1000, the frame loop resumes the parked body
    const inc = [4]u8{ 0, 0, 0x03, 0xE8 }; // +1000
    feedFrame(conn, frame.FRAME_TYPE_WINDOW_UPDATE, 0, 0, &inc);
    feedFrame(conn, frame.FRAME_TYPE_WINDOW_UPDATE, 0, 1, &inc);
    _ = muxFrameLoop(&fc_test_routes, conn);

    // 1000 more went out (the min of the two windows), 3900 remains parked
    try std.testing.expectEqual(@as(usize, 3900), conn.streams[slot].pending_body.len);
}

var ae_seen_buf: [128]u8 = undefined;
var ae_seen_len: usize = 0;

fn aeCheckHandler(_: []const u8, headers: []const hpack.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    ae_seen_len = 0;
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "accept-encoding")) {
            @memcpy(ae_seen_buf[0..h.value.len], h.value);
            ae_seen_len = h.value.len;
        }
    }
    frame.sendResponse(fd, sid, 200, "text/plain", "ok") catch {};
}

const ae_routes = [_]Route{.{ .path = "/static/x", .handler = aeCheckHandler }};

test "zix test: mux passes the accept-encoding request header to the handler" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const opts = core.ServeOpts{ .max_streams = 4, .max_body = 256, .max_header_scratch = 1024 };
    const conn = MuxConn.init(fds[1], opts) orelse return error.OutOfMemory;
    defer conn.deinit();
    conn.phase = .h2;

    var hblk: [256]u8 = undefined;
    var enc = hpack.HpackEncoder.init(&hblk);
    try enc.writeHeader(":method", "GET");
    try enc.writeHeader(":path", "/static/x");
    try enc.writeHeader("accept-encoding", "br;q=1, gzip;q=0.8");
    feedFrame(conn, frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM, 1, enc.encoded());

    ae_seen_len = 0;
    _ = muxFrameLoop(&ae_routes, conn);

    try std.testing.expectEqualStrings("br;q=1, gzip;q=0.8", ae_seen_buf[0..ae_seen_len]);
}
