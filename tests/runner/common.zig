//! Shared utilities for test runners.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const zix = @import("zix");

/// Descriptor reads and writes go through zix's own portable layer, which carries a backend for
/// Windows, Linux and the other POSIX targets. These helpers used raw Linux syscalls, which forced
/// a Windows skip and issued Linux syscall numbers at the BSD and macOS kernels.
const fd_io = zix.utils.fd_io;

/// Readiness deadline for one raw-descriptor read in the TLS and SSE checks. A silent server must
/// fail the check, never hang it, and this replaces the Linux-only SO_RCVTIMEO the helpers used to
/// set on the socket.
const SSE_READ_TIMEOUT_MS: i32 = 5000;

// --------------------------------------------------------- //

/// Wall-clock seconds since the Unix epoch, for a certificate validity check.
///
/// Note:
/// - std.Io carries the clock, so this reads correctly on every target. linux.clock_gettime
///   compiles anywhere but issues a Linux syscall number, so off Linux it filled nothing and the
///   caller verified a certificate against a garbage instant.
///
/// Param:
/// io - std.Io (supplies the real-time clock)
///
/// Return:
/// - i64 seconds since 1970-01-01T00:00:00Z
pub fn realtimeSeconds(io: std.Io) i64 {
    const now = std.Io.Timestamp.now(io, .real);

    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
}

// --------------------------------------------------------- //

/// Args iterator that also works on Windows: std's Iterator.init is POSIX-only
/// in Zig 0.16, Windows needs the allocating variant.
pub fn argsIterator(args: std.process.Args) std.process.Args.Iterator {
    if (comptime builtin.os.tag == .windows) {
        return std.process.Args.Iterator.initAllocator(args, std.heap.smp_allocator) catch {
            std.debug.print("FAIL: args iterator allocation failed\n", .{});
            std.process.exit(1);
        };
    }

    return std.process.Args.Iterator.init(args);
}

/// Scenario labels whose observable behaviour exists on Linux only, so the runner reports them as
/// a visible skip off Linux instead of a failure.
///
/// Note:
/// - Empty on purpose. Compression, the engine-owned WebSocket pump, the response cache, the
///   over-large body drain and HTTP/3 all run under `.ASYNC` now, so every scenario is expected
///   to pass on every platform.
/// - Add a label here only with a reason that is about the PLATFORM, not about the model. A
///   scenario that merely picks `.URING` on Linux does not belong.
const linux_only_labels = [_][]const u8{};

/// Whether a scenario must be skipped on this host because its behaviour is Linux-only. Prints a
/// PASS line with a warn so the suite stays green and the skip stays visible.
///
/// Note:
/// - Matches the label EXACTLY against `linux_only_labels`, which is currently empty. It used to
///   substring-match "epoll" / "uring", which silently stopped matching anything once the
///   per-model runner rows collapsed and their labels lost those words. An exact list cannot rot
///   that way unnoticed.
///
/// Param:
/// label - []const u8 (the scenario label, argv[2] for a standalone runner or Check.label in all_runner)
///
/// Return:
/// - true when the scenario was reported and the caller must return
pub fn skipDispatchOffPlatform(label: []const u8) bool {
    if (comptime builtin.os.tag == .linux) return false;

    for (linux_only_labels) |name| {
        if (std.mem.eql(u8, label, name)) break;
    } else return false;

    std.debug.print("PASS {s} (WARN: Linux-only scenario, skipped on {s})\n", .{
        label,
        @tagName(builtin.os.tag),
    });

    return true;
}

/// Ceiling for the server startup polls (waitForTcpPort / waitForUdsSocket). Generous on purpose:
/// the polls return the instant a port accepts, so a high ceiling costs a fast server nothing and
/// only buys headroom for the heavy TLS / QUIC servers that boot slower when many start at once.
pub const START_TIMEOUT_MS = 12000;

/// Ceiling for a check client waiting on the server it just probed, covering both the first
/// response byte and any quiet stretch inside the body.
///
/// Note:
/// - A healthy check answers in well under a second, so this only fires when a server accepted the
///   connection and then went silent. Without it that wait has no end, and an infinite park is not
///   an error the retry layer can see.
/// - Sized to leave room for three attempts inside one child's isolate.CHECK_TIMEOUT_MS.
pub const RESPONSE_TIMEOUT_MS = 5000;

// --------------------------------------------------------- //
// Runtime fallback note captured from a server's startup stderr (e.g. a server
// configured for io_uring that found io_uring unusable and fell back to EPOLL).
// Transparency: a passing test that silently ran a different model than asked
// would hide that, so waitForTcpPort scrapes the line and report() surfaces it.

var note_buf: [200]u8 = undefined;
var note_len: usize = 0;

/// Return and clear the most recent captured fallback note, if any.
pub fn takeFallbackNote() ?[]const u8 {
    if (note_len == 0) return null;

    const note = note_buf[0..note_len];
    note_len = 0;

    return note;
}

/// Print a PASS line for a runner test, surfacing any captured fallback note
/// (e.g. io_uring -> EPOLL) wrapped onto indented continuation lines so a long
/// reason does not run off one line. The first line keeps the note head up to
/// its ": " separator (the "(<errno>):" lead), then the remainder is word-wrapped
/// at WRAP columns under a 5-space indent aligned with the label. Consumes the note.
pub fn printPass(label: []const u8) void {
    const note = takeFallbackNote() orelse {
        std.debug.print("PASS {s}\n", .{label});
        return;
    };

    const INDENT = "     ";
    const WRAP: usize = 80;

    var rest = note;
    if (std.mem.indexOf(u8, note, ": ")) |ci| {
        std.debug.print("PASS {s} (NOTE: {s}\n", .{ label, note[0 .. ci + 1] });
        rest = note[ci + 2 ..];
    } else {
        std.debug.print("PASS {s} (NOTE:\n", .{label});
    }

    std.debug.print("{s}", .{INDENT});
    var line_len: usize = INDENT.len;
    var first = true;
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    while (it.next()) |word| {
        if (!first and line_len + 1 + word.len > WRAP) {
            std.debug.print("\n{s}{s}", .{ INDENT, word });
            line_len = INDENT.len + word.len;
        } else if (first) {
            std.debug.print("{s}", .{word});
            line_len += word.len;
            first = false;
        } else {
            std.debug.print(" {s}", .{word});
            line_len += 1 + word.len;
        }
    }

    std.debug.print(")\n", .{});
}

/// Read a server child's buffered startup stderr (non-blocking) and, if it logged
/// a runtime fallback, stash that line for report() to surface. Never blocks: the
/// fd is switched to non-blocking and read once (the startup lines are already in
/// the pipe by the time the listener accepts).
fn captureFallbackNote(child: *std.process.Child) void {
    // The note this captures is the io_uring fallback line, which only a Linux host can emit, and
    // the non-blocking switch needs the raw fcntl convention. Both make this Linux-only. It used to
    // run everywhere except Windows while calling std.os.linux.fcntl, so off Linux it aimed a Linux
    // syscall number at a foreign kernel for a note that could not exist there anyway.
    if (comptime builtin.os.tag != .linux) return;

    const f = child.stderr orelse return;
    const fd = f.handle;
    const linux = std.os.linux;

    const cur = linux.fcntl(fd, std.posix.F.GETFL, 0);
    if (std.posix.errno(cur) != .SUCCESS) return;

    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, std.posix.F.SETFL, cur | @as(usize, nonblock));

    var buf: [4096]u8 = undefined;
    const n = fd_io.readOnce(fd, &buf) catch return;
    if (n == 0) return;

    const data = buf[0..n];
    const start = std.mem.indexOf(u8, data, "io_uring unavailable") orelse return;
    var line = data[start..];
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];

    const copy_len = @min(line.len, note_buf.len);
    @memcpy(note_buf[0..copy_len], line[0..copy_len]);
    note_len = copy_len;
}

// --------------------------------------------------------- //

/// Poll TCP port until it accepts connections or timeout_ms elapses. On success,
/// scrape the server child's startup stderr for a runtime fallback note.
///
/// Param:
/// io - std.Io (used to attempt connect and sleep between retries)
/// child - *std.process.Child (the spawned server, for the fallback-note scrape)
/// port - u16 (port number on 127.0.0.1)
/// timeout_ms - u64 (maximum wait time in milliseconds)
///
/// Return:
/// - void on success
/// - error.ServerStartTimeout if port is not open within timeout_ms
pub fn waitForTcpPort(io: std.Io, child: *std.process.Child, port: u16, timeout_ms: u64) !void {
    note_len = 0;
    var elapsed: u64 = 0;

    while (elapsed < timeout_ms) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            elapsed += 50;
            continue;
        };
        const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            elapsed += 50;
            continue;
        };
        stream.close(io);
        captureFallbackNote(child);

        return;
    }

    return error.ServerStartTimeout;
}

/// Poll a Unix socket path until it exists or timeout_ms elapses.
///
/// Param:
/// io - std.Io (used to check file existence and sleep between retries)
/// path - []const u8 (socket file path, absolute or cwd-relative)
/// timeout_ms - u64 (maximum wait time in milliseconds)
///
/// Return:
/// - void on success
/// - error.ServerStartTimeout if path does not appear within timeout_ms
pub fn waitForUdsSocket(io: std.Io, path: []const u8, timeout_ms: u64) !void {
    var elapsed: u64 = 0;

    while (elapsed < timeout_ms) {
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            elapsed += 50;
            continue;
        };

        return;
    }

    return error.ServerStartTimeout;
}

/// Spawn an executable as a background child process.
/// stdout, stdin, and stderr are suppressed.
///
/// Param:
/// io - std.Io
/// server_path - []const u8 (path to the server binary)
///
/// Return:
/// - std.process.Child on success
/// - error from std.process.spawn on failure
pub fn spawnServer(io: std.Io, server_path: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{server_path},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
}

// --------------------------------------------------------- //

// Boundary token for the hand-built multipart/form-data body.
const MULTIPART_BOUNDARY: []const u8 = "zixrunnerboundary";
// File name and bytes the runner uploads and then reads back.
const MULTIPART_NAME: []const u8 = "runner_mp.txt";
const MULTIPART_CONTENT: []const u8 = "zix multipart runner payload";

/// Multipart upload round trip against a running static-serve example: POST a
/// multipart/form-data body to upload_path, then GET the saved file back through the engine
/// static fallback at /<public_dir_upload>/<name> and verify the bytes survive end to end.
///
/// Param:
/// io - std.Io (client transport)
/// port - u16 (server port)
/// upload_path - []const u8 (multipart upload route, e.g. "/upload-multipart")
///
/// Return:
/// - void on success
/// - error.MultipartUploadStatus / error.MultipartServeStatus / error.MultipartServeMismatch on failure
pub fn multipartUploadRoundTrip(io: std.Io, port: u16, upload_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .response_timeout_ms = RESPONSE_TIMEOUT_MS,
        .read_timeout_ms = RESPONSE_TIMEOUT_MS,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buf,
        "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n{s}\r\n--{s}--\r\n",
        .{ MULTIPART_BOUNDARY, MULTIPART_NAME, MULTIPART_CONTENT, MULTIPART_BOUNDARY },
    );

    var ct_buf: [128]u8 = undefined;
    const content_type = try std.fmt.bufPrint(&ct_buf, "multipart/form-data; boundary={s}", .{MULTIPART_BOUNDARY});

    var post_url_buf: [256]u8 = undefined;
    const post_url = try std.fmt.bufPrint(&post_url_buf, "http://127.0.0.1:{d}{s}", .{ port, upload_path });

    var post_resp = try client.post(post_url, .{
        .headers = &.{.{ .name = "content-type", .value = content_type }},
        .body = body,
    });
    defer post_resp.deinit();

    if (post_resp.status() != 200) return error.MultipartUploadStatus;

    var get_url_buf: [256]u8 = undefined;
    const get_url = try std.fmt.bufPrint(&get_url_buf, "http://127.0.0.1:{d}/u/{s}", .{ port, MULTIPART_NAME });

    var get_resp = try client.get(get_url, .{});
    defer get_resp.deinit();

    if (get_resp.status() != 200) return error.MultipartServeStatus;
    if (!std.mem.eql(u8, get_resp.body(), MULTIPART_CONTENT)) return error.MultipartServeMismatch;
}

// --------------------------------------------------------- //

// The GET that opens the SSE stream, the WS upgrade GET, and the content type of a TLS handshake
// record (RFC 8446 5.1). The WS key is the RFC 6455 4.2.2 sample (accept = s3pPLMBiTxaQ9kYGzzhZRbK+xOo=).
const SSE_TLS_REQUEST: []const u8 = "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n";
const WS_TLS_UPGRADE: []const u8 = "GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
const TLS_HANDSHAKE_TYPE: u8 = 22;

/// A connected, handshaked native TLS 1.3 client: the socket fd plus the post-handshake connection
/// (client keys + sequence numbers). Write requests with `connection.writeAppData`, read responses
/// by decrypting each record with `connection.readAppData`.
const TlsClientConn = struct {
    fd: posix.fd_t,
    connection: zix.Tls.Client.ClientConnection,
};

/// Open a TCP connection to 127.0.0.1:port and run the TLS 1.3 handshake with the native zix.Tls
/// client. The caller owns the fd (close it) and drives application data over the returned connection.
fn tlsConnect(io: std.Io, port: u16) !TlsClientConn {
    const fd = try sseConnectLocal(io, port);
    errdefer fd_io.close(fd);

    // io.random is the portable entropy source. linux.getrandom would tie the handshake to one
    // kernel, which is what kept this check Linux-only.
    var client_random: [32]u8 = undefined;
    var ephemeral: [32]u8 = undefined;
    io.random(&client_random);
    io.random(&ephemeral);

    var ch_out: [512]u8 = undefined;
    const started = try zix.Tls.Client.start(.{ .client_random = client_random, .ephemeral_secret = ephemeral }, &ch_out);
    var state = started.state;

    var ch_rec: [600]u8 = undefined;
    ch_rec[0] = TLS_HANDSHAKE_TYPE;
    std.mem.writeInt(u16, ch_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, ch_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(ch_rec[5 .. 5 + started.client_hello.len], started.client_hello);
    try sseWriteAll(fd, ch_rec[0 .. 5 + started.client_hello.len]);

    // server flight: ServerHello + ChangeCipherSpec + the encrypted flight (three records).
    var flight: [4096]u8 = undefined;
    var flen: usize = 0;
    for (0..3) |_| {
        const rec = try sseReadRecord(fd, flight[flen..]);
        flen += rec.len;
    }

    var fin_out: [256]u8 = undefined;
    const finished = try zix.Tls.Client.finish(&state, flight[0..flen], &fin_out);

    try sseWriteAll(fd, finished.client_finished);

    return .{ .fd = fd, .connection = finished.connection };
}

/// Assert an SSE stream runs over TLS (ADR-054): TLS 1.3 handshake with the native zix.Tls client,
/// GET /events, then decrypt the response records and confirm the stream started (Content-Type:
/// text/event-stream) and is streaming (the first event). Reads only the first records then closes,
/// so it works for a bounded stream (the arena example) and an unbounded one (the http1 example).
///
/// Param:
/// io - std.Io (performs the connect, must outlive the check)
/// port - u16 (server port the https example listens on)
///
/// Return:
/// - void on a confirmed SSE-over-TLS stream
/// - error.NoSseOverTls when the markers never appear, plus the handshake / socket errors
pub fn tlsSseFirstEvent(io: std.Io, port: u16) !void {
    var tc = try tlsConnect(io, port);
    defer fd_io.close(tc.fd);

    var enc: [512]u8 = undefined;
    try sseWriteAll(tc.fd, tc.connection.writeAppData(SSE_TLS_REQUEST, &enc));

    // accumulate decrypted plaintext across records until both markers appear. The headers arrive
    // immediately, the first event one tick later, so a small bounded read suffices.
    var seen: [4096]u8 = undefined;
    var seen_len: usize = 0;
    var records: usize = 0;
    while (records < 8) : (records += 1) {
        var rec_buf: [2048]u8 = undefined;
        const rec = try sseReadRecord(tc.fd, &rec_buf);

        var plain: [2048]u8 = undefined;
        const data = tc.connection.readAppData(rec.full, &plain) catch break;
        if (seen_len + data.len > seen.len) break;
        @memcpy(seen[seen_len..][0..data.len], data);
        seen_len += data.len;

        const got = seen[0..seen_len];
        if (std.mem.indexOf(u8, got, "text/event-stream") != null and std.mem.indexOf(u8, got, "tick") != null) {
            return;
        }
    }

    return error.NoSseOverTls;
}

/// Assert a WebSocket echoes over TLS (ADR-055): TLS 1.3 handshake, send the WS upgrade GET, confirm
/// the encrypted 101 (Sec-WebSocket-Accept), send one masked client text frame, then decrypt the
/// echoed server frame and confirm the payload survives the round trip.
///
/// Param:
/// io - std.Io (performs the connect, must outlive the check)
/// port - u16 (server port the wss example listens on)
///
/// Return:
/// - void on a confirmed echo
/// - error.NoWsAccept / error.NoWsEcho on a missing handshake or echo, plus handshake / socket errors
pub fn tlsWsEcho(io: std.Io, port: u16) !void {
    var tc = try tlsConnect(io, port);
    defer fd_io.close(tc.fd);

    var enc: [512]u8 = undefined;
    try sseWriteAll(tc.fd, tc.connection.writeAppData(WS_TLS_UPGRADE, &enc));

    // read records until the encrypted 101 handshake response arrives.
    var got_accept = false;
    var records: usize = 0;
    while (records < 4) : (records += 1) {
        var rec_buf: [2048]u8 = undefined;
        const rec = try sseReadRecord(tc.fd, &rec_buf);

        var plain: [2048]u8 = undefined;
        const data = tc.connection.readAppData(rec.full, &plain) catch break;
        if (std.mem.indexOf(u8, data, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null) {
            got_accept = true;
            break;
        }
    }
    if (!got_accept) return error.NoWsAccept;

    // send one masked client text frame "zixws" (clients MUST mask, RFC 6455 5.3).
    const payload = "zixws";
    const mask = [4]u8{ 0x21, 0x22, 0x23, 0x24 };
    var frame: [2 + 4 + payload.len]u8 = undefined;
    frame[0] = 0x81; // FIN + text
    frame[1] = 0x80 | @as(u8, payload.len); // masked, 5-byte payload
    @memcpy(frame[2..6], &mask);
    for (payload, 0..) |b, i| frame[6 + i] = b ^ mask[i % 4];

    var enc2: [128]u8 = undefined;
    try sseWriteAll(tc.fd, tc.connection.writeAppData(&frame, &enc2));

    // the server echoes one unmasked text frame, decrypt it and confirm the payload round-tripped.
    var rec_buf: [2048]u8 = undefined;
    const echo_rec = try sseReadRecord(tc.fd, &rec_buf);

    var plain: [2048]u8 = undefined;
    const data = try tc.connection.readAppData(echo_rec.full, &plain);
    if (std.mem.indexOf(u8, data, payload) == null) return error.NoWsEcho;
}

/// Open a blocking TCP connection to 127.0.0.1:port.
///
/// Note:
/// - std.Io.net does the connect, so this works on every target. The previous raw-socket form
///   issued Linux syscalls and had to refuse Windows outright.
/// - A stuck read is bounded by waitReadable in sseReadAll rather than by SO_RCVTIMEO, because the
///   socket option does not have one portable shape across these platforms.
///
/// Param:
/// io - std.Io (performs the connect, must outlive the returned descriptor)
/// port - u16 (server port on the loopback address)
///
/// Return:
/// - posix.fd_t the caller owns and must close with fd_io.close
/// - error.ConnectFailed when the connection could not be established
fn sseConnectLocal(io: std.Io, port: u16) !posix.fd_t {
    const addr = std.Io.net.IpAddress.resolve(io, "127.0.0.1", port) catch return error.ConnectFailed;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return error.ConnectFailed;

    return stream.socket.handle;
}

const SseRecord = struct {
    full: []const u8,
    len: usize,
};

fn sseReadRecord(fd: posix.fd_t, buf: []u8) !SseRecord {
    try sseReadAll(fd, buf[0..5]);

    const length = std.mem.readInt(u16, buf[3..5], .big);
    if (5 + length > buf.len) return error.RecordTooLarge;

    try sseReadAll(fd, buf[5 .. 5 + length]);

    return .{ .full = buf[0 .. 5 + length], .len = 5 + length };
}

/// Read exactly buf.len bytes, bounding the wait so a silent server fails the check instead of
/// hanging it. fd_io carries the per-platform read, this adds only the readiness deadline.
fn sseReadAll(fd: posix.fd_t, buf: []u8) !void {
    var filled: usize = 0;

    while (filled < buf.len) {
        if (!fd_io.waitReadable(fd, SSE_READ_TIMEOUT_MS)) return error.ReadTimeout;

        const got = try fd_io.readOnce(fd, buf[filled..]);
        if (got == 0) return error.ConnectionClosed;

        filled += got;
    }
}

fn sseWriteAll(fd: posix.fd_t, bytes: []const u8) !void {
    return fd_io.writeAll(fd, bytes);
}
